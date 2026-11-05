
### Prerequisites
* iOS 15.0 or newer.
* Xcode 14.0 or newer.
* A registered Telegram Bot via [@BotFather](https://t.me/botfather).

### 1. Installation

The recommended way to install the Telegram Login SDK is via **Swift Package Manager (SPM)**.

1. In Xcode, navigate to **File > Add Packages...**
2. Enter the repository URL: `https://github.com/TelegramMessenger/telegram-login-ios`
3. Select the version rule and add the `TelegramLogin` package to your primary app target.

### 2. Setup in BotFather
To securely log users in, your app must be registered with your bot. Open [**@BotFather**](https://t.me/botfather) and navigate to **Bot Settings > Login Widget**.

Provide your app's exact identifiers to establish a secure handshake:

* **Bundle ID**: Your app's unique identifier (e.g., `com.yourcompany.app`).
* **Team ID**: Your 10-character Apple Developer Team ID found in your Apple Developer account (e.g., `ABCDE12345`).

#### Redirect URI Configuration
You must register a redirect URI so the Telegram app knows where to send the user back after a successful login.

* **Universal Link (Highly Recommended)**: Telegram automatically generates and registers a secure domain for you: `https://app{appid}-login.tg.dev`. This prevents malicious apps from hijacking the login callback.
* **Custom Scheme (Fallback)**: `yourapp://tglogin`. Only use this if you cannot support Universal Links.

---

### 3. Project Configuration (Xcode)
To allow your app to intercept the login callback from the Telegram app, you must configure your project's routing capabilities.

#### Enabling Universal Links
1. Select your app target and go to **Signing & Capabilities**.
2. Click **+ Capability** and add **Associated Domains**.
3. Add the exact domain provided by BotFather, prefixed with `applinks:`
   * Example: `applinks:app123456-login.tg.dev`

> **Tip:** During development, Apple's CDN might heavily cache your Universal Links configuration. To bypass this cache and force iOS to fetch the latest configuration directly, append `?mode=developer` to your Associated Domains entry (e.g., `applinks:app123456-login.tg.dev?mode=developer`).
>
> *Note: For this to work on a physical device, you must toggle on **Associated Domains Development** in your iPhone's Developer settings. Be sure to remove this query parameter before distributing your app to production.*

#### Enabling Custom URL Scheme (If not using Universal Links)
1. Open your project's **Info.plist**.
2. Add a new **URL types** array.
3. Set the **URL Identifier** to your Bundle ID.
4. Set the **URL Schemes** to your chosen scheme (e.g., `yourapp`).

---

### 4. SDK Initialization
Initialize the global SDK configuration at your app's entry point. This ensures the SDK knows which bot is requesting the login.

**SwiftUI Example:**
```swift
import SwiftUI
import TelegramLogin

@main
struct YourApp: App {
    init() {
        TelegramLogin.configure(
            clientId: "YOUR_BOT_CLIENT_ID",
            redirectUri: "https://app123456-login.tg.dev",
            scopes: ["profile", "phone"]
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

#### Configuration Options

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `clientId` | String | **Required.** Your Bot's Client ID provided by @BotFather. |
| `redirectUri` | String | **Required.** The exact return URL. |
| `scopes` | [String] | **Required.** Requested permissions. |

---

### 5. Login & Callbacks

To trigger the login flow, call `TelegramLogin.login(completion:)` from your view or view model.

```swift
TelegramLogin.login { result in
    switch result {
    case .success(let loginData):
        print("Login successful! Token: \(loginData.idToken)")
    case .failure(let error):
        print("Login failed: \(error.localizedDescription)")
    }
}
```

The SDK automatically selects the best available flow:

1. **Telegram App (preferred)** — If installed, the user is redirected to the Telegram app for authorization. After approval, the user is sent back to your app via the Redirect URI.
2. **In-App Web Auth (fallback)** — If Telegram is not installed, the SDK presents a secure `ASWebAuthenticationSession` sheet. The callback is handled internally and the result is delivered through the same completion handler.

#### Binding the Token with a Nonce

Pass a `nonce` to bind the id_token to one login. It is sent unchanged as the OIDC `nonce` parameter and returned in the id_token's `nonce` claim, so your backend can reject a token issued for another request.

```swift
TelegramLogin.login(nonce: serverNonce) { result in
    // Verify that the id_token's `nonce` claim equals serverNonce.
}
```

#### Intercepting the Callback (Telegram App Flow)

When the user approves login in the Telegram app, iOS opens your app using the Redirect URI. You must pass this URL to the SDK so it can exchange the authorization code for a token.

**SwiftUI:** Use the `.onOpenURL` modifier on your root view:
```swift
ContentView()
    .onOpenURL { url in
        if url.host == "app123456-login.tg.dev" {
            TelegramLogin.handle(url)
        }
    }
```

**UIKit:** In your `SceneDelegate`, intercept the URL context:
```swift
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url, url.host == "app123456-login.tg.dev" else { return }
    TelegramLogin.handle(url)
}
```

#### Error Handling

The completion handler may return the following errors:

| Error | Description |
| :--- | :--- |
| `.notConfigured` | `TelegramLogin.configure()` was not called before `login()`. |
| `.noAuthorizationCode` | The callback URL did not contain an authorization code. |
| `.serverError(statusCode:)` | The server returned a non-200 HTTP status code. |
| `.requestFailed(String)` | A general request failure with a descriptive message. |
| `.cancelled` | The user dismissed the in-app authentication sheet. |

> **Important:** The `idToken` returned upon success is a JWT. You **must** send this token to your backend to cryptographically verify its validity before logging the user into your system. Read more about [validating ID tokens](https://core.telegram.org/bots/telegram-login#validating-id-tokens) in the core documentation.
