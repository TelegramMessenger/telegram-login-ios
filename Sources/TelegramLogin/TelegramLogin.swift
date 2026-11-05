import Foundation
import AuthenticationServices
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Result of a successful Telegram login containing the id_token.
public struct LoginData: Sendable {
    /// The OpenID Connect id_token returned by the server.
    public let idToken: String

    public init(idToken: String) {
        self.idToken = idToken
    }
}

/// Errors that can occur during Telegram login.
public enum TelegramLoginError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case noAuthorizationCode
    case serverError(statusCode: Int)
    case requestFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "TelegramLogin is not configured. Call TelegramLogin.configure() first."
        case .noAuthorizationCode:
            return "No authorization code found in callback URL."
        case .serverError(let code):
            return "Server returned HTTP \(code)."
        case .requestFailed(let message):
            return message
        case .cancelled:
            return "Login was cancelled."
        }
    }
}

/// Entry point for Telegram OAuth login.
public enum TelegramLogin {

    private struct Configuration: Sendable {
        let clientId: String
        let redirectUri: String
        let scopes: [String]
        let fallbackScheme: String?
    }

    private static var _configuration: Configuration?
    private static var _pendingCompletion: (@Sendable (Result<LoginData, Error>) -> Void)?
    private static var _authSession: ASWebAuthenticationSession?
    private static var _codeVerifier: String?
    private static var _nonce: String?

    private static let baseURL = "https://oauth.telegram.org"

    /// Set up credentials. Must be called before `login()`. `fallbackScheme` is sometimes used on iOS < 17.4.
    @MainActor
    public static func configure(
        clientId: String,
        redirectUri: String,
        scopes: [String],
        fallbackScheme: String? = nil
    ) {
        _configuration = Configuration(
            clientId: clientId,
            redirectUri: redirectUri,
            scopes: scopes,
            fallbackScheme: fallbackScheme
        )
    }
    /// Start the Telegram login flow. `nonce` is passed unchanged as the OIDC nonce and
    /// returned in the id_token's `nonce` claim, binding the token to this login.
    @MainActor
    public static func login(
        nonce: String? = nil,
        completion: @escaping @Sendable (Result<LoginData, Error>) -> Void
    ) {
        guard let config = _configuration else {
            completion(.failure(TelegramLoginError.notConfigured))
            return
        }

        _pendingCompletion = completion
        _codeVerifier = generateCodeVerifier()
        _nonce = nonce

        Task {
            await performLogin(config: config, completion: completion)
        }
    }

    @MainActor
    private static func performLogin(
        config: Configuration,
        completion: @escaping @Sendable (Result<LoginData, Error>) -> Void
    ) async {
        #if canImport(UIKit)
        if let tgCheck = URL(string: "tg://resolve"),
           UIApplication.shared.canOpenURL(tgCheck) {
            if let crossAppURL = try? await fetchCrossAppURL(config: config),
               UIApplication.shared.canOpenURL(crossAppURL) {
                await UIApplication.shared.open(crossAppURL)
                return
            }
        }
        #endif

        startWebAuthSession(config: config, completion: completion)
    }

    /// Handle the OAuth callback URL and exchange the code for an id_token.
    @MainActor
    public static func handle(
        _ url: URL,
        completion: (@Sendable (Result<LoginData, Error>) -> Void)? = nil
    ) {
        let callback = completion ?? _pendingCompletion
        _pendingCompletion = nil

        guard let callback else { return }

        guard let config = _configuration else {
            callback(.failure(TelegramLoginError.notConfigured))
            return
        }

        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            callback(.failure(TelegramLoginError.noAuthorizationCode))
            return
        }

        Task {
            do {
                let token = try await exchangeCode(code, config: config)
                callback(.success(LoginData(idToken: token)))
            } catch {
                callback(.failure(error))
            }
        }
    }

    @MainActor
    private static func startWebAuthSession(
        config: Configuration,
        completion: @escaping @Sendable (Result<LoginData, Error>) -> Void
    ) {
        guard let authURL = buildAuthURL(config: config) else {
            completion(.failure(TelegramLoginError.requestFailed("Could not build auth URL")))
            return
        }

        let handleResult: (URL?, Error?) -> Void = { callbackURL, error in
            _authSession = nil

            if let error {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    completion(.failure(TelegramLoginError.cancelled))
                } else {
                    completion(.failure(error))
                }
                return
            }

            guard let callbackURL else {
                completion(.failure(TelegramLoginError.noAuthorizationCode))
                return
            }

            Task { @MainActor in
                handle(callbackURL, completion: completion)
            }
        }

        let session: ASWebAuthenticationSession

        if #available(iOS 17.4, *),
           let components = URLComponents(string: config.redirectUri),
           components.scheme == "https",
           let host = components.host {
            let path = components.path.isEmpty ? "/" : components.path
            let callback = ASWebAuthenticationSession.Callback.https(host: host, path: path)
            session = ASWebAuthenticationSession(url: authURL, callback: callback) { callbackURL, error in
                handleResult(callbackURL, error)
            }
        } else {
            let callbackScheme = config.fallbackScheme ?? URLComponents(string: config.redirectUri)?.scheme
            session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                handleResult(callbackURL, error)
            }
        }

        #if canImport(UIKit)
        session.presentationContextProvider = PresentationContextProvider.shared
        #endif
        session.prefersEphemeralWebBrowserSession = false

        _authSession = session
        session.start()
    }

    private static func fetchCrossAppURL(config: Configuration) async throws -> URL? {
        guard var components = URLComponents(string: "\(baseURL)/crossapp") else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "ios_sdk", value: "1"),
        ]
        if let verifier = _codeVerifier {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let nonce = _nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        struct CrossAppResponse: Decodable { let url: String? }
        return try JSONDecoder().decode(CrossAppResponse.self, from: data)
            .url
            .flatMap(URL.init(string:))
    }

    private static func buildAuthURL(config: Configuration) -> URL? {
        guard var components = URLComponents(string: "\(baseURL)/auth") else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "ios_sdk", value: "1"),
        ]
        if let verifier = _codeVerifier {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let nonce = _nonce {
            queryItems.append(URLQueryItem(name: "nonce", value: nonce))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func exchangeCode(
        _ code: String,
        config: Configuration
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/token") else {
            throw TelegramLoginError.requestFailed("Invalid token endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        var bodyItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
        ]
        if let verifier = _codeVerifier {
            bodyItems.append(URLQueryItem(name: "code_verifier", value: verifier))
            _codeVerifier = nil
        }
        var body = URLComponents()
        body.queryItems = bodyItems
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TelegramLoginError.serverError(statusCode: statusCode)
        }

        struct TokenResponse: Decodable {
            let id_token: String?
            let error: String?
        }

        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let token = parsed.id_token {
            return token
        }
        throw TelegramLoginError.requestFailed(
            parsed.error ?? "Unexpected token response"
        )
    }
}

private func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func codeChallenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

#if canImport(UIKit)
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
#endif
