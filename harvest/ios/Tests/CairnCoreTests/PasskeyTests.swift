import Foundation
import Testing
@testable import CairnCore

// What the dashboard (@simplewebauthn/server) sends for a sign-in with no named passkey, and for making one.
private let challenge = Data((0..<32).map { UInt8($0) })
private func options(_ extra: String) -> Data {
    Data("""
    {"challengeId":"abc123","options":{"challenge":"\(Base64URL.encode(challenge))",\(extra)}}
    """.utf8)
}

@Suite struct Base64URLTests {
    @Test func roundTripsWithoutPaddingOrUnsafeCharacters() {
        for n in 0..<12 {
            let data = Data((0..<n).map { UInt8(255 - $0) })
            let text = Base64URL.encode(data)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == data)
        }
    }
    @Test func decodesWhatWebAuthnProduces() {
        #expect(Base64URL.decode("AQID") == Data([1, 2, 3]))
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
    }
}

@Suite struct PasskeyCodecTests {
    @Test func readsASignInRequestWithNoNamedPasskey() throws {
        let r = try PasskeyCodec.signInRequest(from: options(#""rpId":"cairn.example.lan","userVerification":"required""#))
        #expect(r.challengeID == "abc123")
        #expect(r.challenge == challenge)
        #expect(r.rpID == "cairn.example.lan")
        #expect(r.allowedCredentialIDs.isEmpty)
    }

    @Test func readsTheNamedPasskeysOfAnOrdinarySignIn() throws {
        let r = try PasskeyCodec.signInRequest(from: options(#""rpId":"h","allowCredentials":[{"id":"AQID","type":"public-key"}]"#))
        #expect(r.allowedCredentialIDs == [Data([1, 2, 3])])
    }

    @Test func readsACreateRequest() throws {
        let r = try PasskeyCodec.createRequest(from: options(#""rp":{"name":"Cairn","id":"h"},"user":{"id":"BAUG","name":"owner","displayName":"owner"},"excludeCredentials":[{"id":"AQID","type":"public-key"}]"#))
        #expect(r.rpID == "h")
        #expect(r.userID == Data([4, 5, 6]))
        #expect(r.userName == "owner")
        #expect(r.excludedCredentialIDs == [Data([1, 2, 3])])
    }

    @Test func refusesWhatIsMissing() {
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: Data("{}".utf8)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: options(#""rpId":"""#)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.signInRequest(from: Data(#"{"challengeId":"x","options":{"rpId":"h","challenge":"!!"}}"#.utf8)) }
        #expect(throws: PasskeyCodecError.self) { try PasskeyCodec.createRequest(from: options(#""rp":{"id":"h"}"#)) }
    }

    @Test func answersASignInInTheShapeTheDashboardVerifies() throws {
        let req = try PasskeyCodec.signInRequest(from: options(#""rpId":"h""#))
        let body = try PasskeyCodec.signInBody(for: req, credentialID: Data([1, 2, 3]), clientDataJSON: Data("cd".utf8), authenticatorData: Data([9, 9]), signature: Data([7]), userHandle: Data([4, 5, 6]))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["challengeId"] as? String == "abc123")
        let cred = try #require(root["response"] as? [String: Any])
        #expect(cred["id"] as? String == "AQID")
        #expect(cred["rawId"] as? String == "AQID")
        #expect(cred["type"] as? String == "public-key")
        #expect(cred["authenticatorAttachment"] as? String == "platform")
        #expect(cred["clientExtensionResults"] as? [String: Any] != nil)
        let inner = try #require(cred["response"] as? [String: Any])
        #expect(Base64URL.decode(inner["clientDataJSON"] as! String) == Data("cd".utf8))
        #expect(Base64URL.decode(inner["authenticatorData"] as! String) == Data([9, 9]))
        #expect(Base64URL.decode(inner["signature"] as! String) == Data([7]))
        #expect(Base64URL.decode(inner["userHandle"] as! String) == Data([4, 5, 6]))
    }

    @Test func leavesOutAnEmptyUserHandle() throws {
        let req = try PasskeyCodec.signInRequest(from: options(#""rpId":"h""#))
        let body = try PasskeyCodec.signInBody(for: req, credentialID: Data([1]), clientDataJSON: Data([1]), authenticatorData: Data([1]), signature: Data([1]), userHandle: Data())
        let cred = try #require((JSONSerialization.jsonObject(with: body) as? [String: Any])?["response"] as? [String: Any])
        #expect((cred["response"] as? [String: Any])?["userHandle"] == nil)
    }

    @Test func answersACreateWithANameAndTransports() throws {
        let req = try PasskeyCodec.createRequest(from: options(#""rp":{"id":"h"},"user":{"id":"BAUG","name":"owner"}"#))
        let body = try PasskeyCodec.createBody(for: req, name: "Twesh's iPhone", credentialID: Data([1, 2, 3]), clientDataJSON: Data("cd".utf8), attestationObject: Data([0xA1]))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["name"] as? String == "Twesh's iPhone")
        let cred = try #require(root["response"] as? [String: Any])
        let inner = try #require(cred["response"] as? [String: Any])
        #expect(Base64URL.decode(inner["attestationObject"] as! String) == Data([0xA1]))
        #expect((inner["transports"] as? [String])?.contains("internal") == true)
    }
}

// MARK: - Client against a scripted dashboard

private final class ScriptedDashboard: HTTPTransport, @unchecked Sendable {
    var routes: [String: HTTPResponse] = [:]
    var seen: [HTTPRequest] = []
    var offline = false
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        seen.append(request)
        if offline { throw HTTPTransportError(.offline) }
        return routes["\(request.method) \(request.target)"] ?? HTTPResponse(status: 404)
    }
}

private func json(_ status: Int, _ text: String) -> HTTPResponse { HTTPResponse(status: status, body: Data(text.utf8)) }

@Suite struct DashboardAuthClientTests {
    @Test func readsWhoTheDashboardThinksYouAre() async throws {
        let d = ScriptedDashboard()
        d.routes["GET /api/auth/session"] = json(200, #"{"authenticated":true,"method":"tailnet","actor":"a@b","fresh":false,"passkeys":1,"can_enrol":false,"on_tailnet":true}"#)
        let s = try await DashboardAuthClient(transport: d).session()
        #expect(s.authenticated && s.viaTailnet && !s.viaPasskey)
        #expect(s.passkeys == 1 && s.onTailnet && !s.canEnrol)
    }

    @Test func signInAsksForAChallengeNamingNoPasskeyAndSendsJSON() async throws {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/login-options"] = json(200, String(decoding: options(#""rpId":"h""#), as: UTF8.self))
        let r = try await DashboardAuthClient(transport: d).signInChallenge()
        #expect(r.rpID == "h")
        let sent = try #require(d.seen.first)
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(String(decoding: sent.body, as: UTF8.self).contains(#""discoverable":true"#))
    }

    @Test func saysSoWhenThereIsNoPasskeyYet() async {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/login-options"] = json(409, #"{"statusMessage":"no passkey is enrolled yet"}"#)
        await #expect(throws: DashboardAuthError.noPasskeyYet) { try await DashboardAuthClient(transport: d).signInChallenge() }
    }

    @Test func aFirstPasskeyNeedsTheCodeOrATailnet() async {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/register-options"] = json(401, #"{"statusMessage":"enrolment needs a Tailnet device or the code on the host"}"#)
        await #expect(throws: DashboardAuthError.needsCodeOrTailnet) { try await DashboardAuthClient(transport: d).createChallenge() }
    }

    @Test func aLaterPasskeyNeedsAFreshOne() async {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/register-options"] = json(401, #"{"statusMessage":"reauth_required"}"#)
        await #expect(throws: DashboardAuthError.needsRecentPasskey) { try await DashboardAuthClient(transport: d).createChallenge() }
    }

    @Test func sendsTheOneTimeCodeOnlyWhenGiven() async throws {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/register-options"] = json(200, String(decoding: options(#""rp":{"id":"h"},"user":{"id":"BAUG","name":"o"}"#), as: UTF8.self))
        _ = try await DashboardAuthClient(transport: d).createChallenge(bootstrapCode: "  c0de \n")
        #expect(String(decoding: d.seen[0].body, as: UTF8.self).contains(#""bootstrapCode":"c0de""#))
        _ = try await DashboardAuthClient(transport: d).createChallenge()
        #expect(d.seen[1].body == Data("{}".utf8))
    }

    @Test func aRefusedAnswerCarriesTheDashboardsReason() async {
        let d = ScriptedDashboard()
        d.routes["POST /api/auth/login-verify"] = json(401, #"{"statusMessage":"passkey rejected"}"#)
        await #expect(throws: DashboardAuthError.rejected("passkey rejected")) { try await DashboardAuthClient(transport: d).finishSignIn(Data("{}".utf8)) }
    }

    @Test func noNetworkIsUnreachableNotAnObscureError() async {
        let d = ScriptedDashboard()
        d.offline = true
        await #expect(throws: DashboardAuthError.unreachable) { try await DashboardAuthClient(transport: d).session() }
    }

    @Test func everyErrorHasWordsAPersonCanActOn() {
        for e in [DashboardAuthError.unreachable, .noPasskeyYet, .needsCodeOrTailnet, .needsRecentPasskey, .rejected("x"), .unexpected(500)] {
            #expect((e.errorDescription ?? "").count > 20)
        }
    }
}

@Suite struct DashboardAddressTests {
    @Test func theDashboardIsTheServersHostOnTheOrdinaryPort() {
        #expect(DashboardAddress.url(forServer: "https://cairn.example.lan:8444")?.absoluteString == "https://cairn.example.lan")
        #expect(DashboardAddress.url(forServer: "  https://cairn.example.lan/v1/x?y=1 ")?.absoluteString == "https://cairn.example.lan")
        #expect(DashboardAddress.url(forServer: "https://cairn.example.lan")?.absoluteString == "https://cairn.example.lan")
    }

    @Test func saysWhyThereIsNoDashboardAddress() {
        #expect(DashboardAddress.problem(forServer: "") == .noServer)
        #expect(DashboardAddress.problem(forServer: "not a url") == .noServer)
        #expect(DashboardAddress.problem(forServer: "http://cairn.example.lan") == .notHTTPS)
        #expect(DashboardAddress.problem(forServer: "https://192.168.1.20:8444") == .ipAddress)
        #expect(DashboardAddress.problem(forServer: "https://[fd7a:115c::1]:8444") == .ipAddress)
        #expect(DashboardAddress.problem(forServer: "https://cairn.example.lan:8444") == nil)
        #expect(DashboardAddress.url(forServer: "https://192.168.1.20") == nil)
        for p in [DashboardAddress.Problem.noServer, .ipAddress, .notHTTPS] { #expect(DashboardAddress.words(for: p).count > 20) }
    }

    @Test func aHostThatLooksLikeNumbersButIsNotAnAddressIsAName() {
        #expect(DashboardAddress.problem(forServer: "https://1.2.3.example.lan") == nil)
        #expect(DashboardAddress.problem(forServer: "https://300.1.1.1") == nil) // not a valid address, so a (odd) name
    }
}

@Suite struct DashboardAddressChoiceTests {
    @Test func theSameHostIsTheDefaultAndIgnoresWhatWasTyped() {
        #expect(DashboardAddress.url(forServer: "https://cairn.example.lan:8444", sameHost: true, typed: "https://other.example")?.absoluteString == "https://cairn.example.lan")
    }

    @Test func aTypedAddressIsUsedAsTypedWithItsPort() {
        #expect(DashboardAddress.url(forServer: "https://cairn.example.lan:8444", sameHost: false, typed: "https://dash.example.lan:3443/trips")?.absoluteString == "https://dash.example.lan:3443")
        #expect(DashboardAddress.url(forServer: "", sameHost: false, typed: "dash.example.lan")?.absoluteString == "https://dash.example.lan")
        #expect(DashboardAddress.url(forServer: "", sameHost: false, typed: "  dash.example.lan  ")?.absoluteString == "https://dash.example.lan")
    }

    @Test func aTypedAddressNeedsNoServer() {
        #expect(DashboardAddress.problem(forServer: "", sameHost: false, typed: "dash.example.lan") == nil)
    }

    @Test func aTypedAddressIsChecked() {
        #expect(DashboardAddress.problem(forServer: "https://a.example", sameHost: false, typed: "") == .noDashboardAddress)
        #expect(DashboardAddress.problem(forServer: "https://a.example", sameHost: false, typed: "http://dash.example") == .notHTTPS)
        #expect(DashboardAddress.problem(forServer: "https://a.example", sameHost: false, typed: "10.0.0.5") == .ipAddress)
        #expect(DashboardAddress.url(forServer: "https://a.example", sameHost: false, typed: "10.0.0.5") == nil)
        #expect(DashboardAddress.words(for: .noDashboardAddress).count > 10)
    }

    @Test func theSameHostStillNeedsAServer() {
        #expect(DashboardAddress.problem(forServer: "", sameHost: true, typed: "dash.example.lan") == .noServer)
    }
}
