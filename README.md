# Fingerprinting Techniques

SwiftUI demo app for a talk about iOS cross-app tracking signals and how their usefulness changed over time.

The app has one tab per technique:

- Battery level and charging state
- Public and local IP address
- Gyroscope and accelerometer data
- Kernel boot time and monotonic uptime
- Carrier name, MCC, MNC, and ISO country code
- Free disk space

The app is educational and does not persist or combine these values into an identifier. `PrivacyInfo.xcprivacy` declares the required-reason API categories used for system boot time and disk space.

# Context

It's a demo app I presented during my talk at Objetive By The Sea v9 in Hawaii, USA
