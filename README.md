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

#### Deep Linking Setup
Note: This demo app already includes deep linking configuration. If you're creating your own implementation, ensure your Android Manifest (`android/app/src/main/AndroidManifest.xml`) includes:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<!-- Deep Link Configuration -->
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="blinkpay" 
          android:host="test-app" 
          android:pathPrefix="/return"/>
</intent-filter>
```

## Running the Application

Run the app in debug mode:
```bash
flutter run
```
## Contributing

We welcome contributions from the community! Your pull request will be reviewed by our team.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.