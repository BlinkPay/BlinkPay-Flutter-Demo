# BlinkPay Flutter Mobile App Demo

A Flutter project showcasing how to integrate WebView-based e-commerce functionality with the BlinkPay payment gateway. This project demonstrates a mobile implementation of BlinkPay's payment system using Flutter's WebView capabilities and deep linking for seamless payment flow.

## Tools & Technologies

- **Flutter**: Cross-platform framework for building mobile applications
- **WebView**: For rendering web-based payment interfaces
- **Deep Linking**: To handle payment callbacks and app navigation
- **BlinkPay**: Secure payment gateway integration for processing payments

## Prerequisites

Ensure you have the following installed:

- Flutter SDK (latest stable version)
- Android Studio or VS Code with Flutter extensions
- Xcode (for iOS development, macOS only)
- Git
- A BlinkPay Account (for processing payments)

## Getting Started

### Installation

1. Clone the Repository:
```bash
git clone https://github.com/BlinkPay/blinkpay_flutter_mobile_app_demo
cd blinkpay_flutter_mobile_app_demo
```

2. Install Dependencies:
```bash
flutter pub get
```

### Development Environment Setup

#### Android Setup
1. Open Android Studio
2. Install the Flutter and Dart plugins
3. Configure an Android device or emulator
4. Verify USB debugging is enabled if using a physical device

#### iOS Setup (macOS only)
1. Install Xcode from the Mac App Store
2. Configure an iOS simulator or device
3. Install CocoaPods if not already installed:
```bash
sudo gem install cocoapods
```

### Configuration

#### BlinkPay Configuration

1. Log into [BlinkPay Merchant Portal](https://merchants.blinkpay.co.nz/settings/api)
2. Navigate to your app under Settings/API
3. Add your Redirect URI e.g. `blinkpay://test-app/return` to your whitelist redirect URLs and save
4. Copy the API key and generate a new secret using "Rotate Secret"

#### Environment Configuration

Create a `.env` file at the root of your project:
```
BLINKPAY_API_URL=https://sandbox.debit.blinkpay.co.nz # Use https://debit.blinkpay.co.nz for production
BLINKPAY_CLIENT_ID=<your_blinkpay_api_key>
BLINKPAY_CLIENT_SECRET=<your_blinkpay_secret>
APP_REDIRECT_URI=blinkpay://test-app/return
```

### Required Manifest Configurations

The below lists general app configurations needed to connect to our API and use the service. These have already been included in the codebase but are noted here in case you are creating your own app.

#### Android Configuration

```xml
<!-- Add this permission at the top level -->
<uses-permission android:name="android.permission.INTERNET"/>

<!-- Add this queries section for URL handling capability -->
<queries>
    <intent>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" />
    </intent>
</queries>
```

If you're using a custom URL scheme for payment redirects (e.g., `blinkpay://`), you'll need to add the following configurations to your app:

```xml
<!-- Inside the <activity> tag, add this intent filter for URL scheme handling -->
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="blinkpay" android:host="test-app" android:pathPrefix="/return"/>
</intent-filter>
```

Note: Replace with your actual bundle identifier.

#### iOS Configuration

If you're using a custom URL scheme for payment redirects (e.g., `blinkpay://`), you'll need to add this URL scheme configuration to your `ios/Runner/Info.plist`:

```
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>blinkpay</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.example.blinkpay</string>
    </dict>
</array>
```

Note: Replace with your actual bundle identifier.


## Running the Application

Before running the application, you need to set up your development environment with an emulator or physical device:

Ensure you have either:
- An Android emulator running (via Android Studio's Device Manager)
- An iOS simulator running (via Xcode's Developer Tools)
- A physical device connected with USB debugging enabled

See Flutter's device setup guides for [macOS](https://docs.flutter.dev/get-started/install/macos#set-up-your-android-device), [Windows](https://docs.flutter.dev/get-started/install/windows#set-up-your-android-device), or [Linux](https://docs.flutter.dev/get-started/install/linux#set-up-your-android-device).


Run the app in debug mode:
```bash
flutter run
```
## Contributing

We welcome contributions from the community! Your pull request will be reviewed by our team.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.