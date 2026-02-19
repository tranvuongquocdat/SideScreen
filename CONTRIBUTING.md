# Contributing to Side Screen

Thank you for your interest in contributing to Side Screen! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Ways to Contribute](#ways-to-contribute)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Pull Request Process](#pull-request-process)
- [Issue Guidelines](#issue-guidelines)

---

## Code of Conduct

Please be respectful and constructive in all interactions. We're building something together, and a positive environment helps everyone contribute their best work.

---

## Ways to Contribute

### Report Bugs

Found a bug? Please open an issue with:
- Clear description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Your environment (macOS version, Android version, device model)

### Suggest Features

Have an idea? Open a feature request issue with:
- Description of the feature
- Use case / why it would be helpful
- Any implementation ideas (optional)

### Submit Code

Ready to code? Great! See the development setup below.

### Improve Documentation

Documentation improvements are always welcome:
- Fix typos
- Clarify instructions
- Add examples
- Translate to other languages

### Star the Repository

The simplest way to help - star the repo to help others discover it!

---

## Development Setup

### Prerequisites

**macOS Development:**
- macOS 14 (Sonoma) or later
- Xcode 15+ or Swift toolchain
- Swift 5.9+

**Android Development:**
- Android Studio Hedgehog or later
- JDK 17
- Android SDK 34

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/tranvuongquocdat/SideScreen.git
cd SideScreen

# Build macOS app
cd MacHost
swift build

# Build Android app
cd ../AndroidClient
./gradlew assembleDebug
```

### Project Structure

```
SideScreen/
├── MacHost/                 # macOS Swift application
│   └── Sources/             # Swift source files
├── AndroidClient/           # Android Kotlin application
│   └── app/src/main/        # Kotlin source files
├── scripts/                 # Build and install scripts
├── resources/               # Assets (logos, screenshots)
└── website/                 # Landing page
```

---

## Coding Standards

### Swift (macOS)

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and small

```swift
// Good
func startStreaming() throws {
    // Clear, focused implementation
}

// Avoid
func doStuff() {
    // Vague naming, unclear purpose
}
```

### Kotlin (Android)

- Follow Kotlin coding conventions
- Use Kotlin idioms (null safety, extension functions)
- Prefer immutability (`val` over `var`)
- Use meaningful names

```kotlin
// Good
private fun connectToHost(host: String, port: Int): Result<Connection>

// Avoid
private fun connect(h: String, p: Int): Any?
```

### General Guidelines

- Write self-documenting code
- Add comments only when the "why" isn't obvious
- Keep commits focused and atomic
- Test your changes before submitting

---

## Pull Request Process

### Before You Start

1. Check existing issues/PRs to avoid duplicate work
2. For major changes, open an issue first to discuss
3. Fork the repository and create a feature branch

### Branch Naming

Use descriptive branch names:
- `feature/wifi-support`
- `fix/connection-timeout`
- `docs/installation-guide`

### Commit Messages

Write clear, descriptive commit messages:

```
feat: add WiFi Direct connection support

- Implement mDNS discovery for nearby devices
- Add WiFi connection option in settings
- Handle connection state transitions

Closes #42
```

### Submitting

1. Ensure your code builds without errors
2. Test your changes on real devices if possible
3. Update documentation if needed
4. Create a pull request with:
   - Clear description of changes
   - Link to related issue (if any)
   - Screenshots for UI changes

### Review Process

- Maintainers will review your PR
- Be responsive to feedback
- Make requested changes promptly
- Once approved, your PR will be merged

---

## Issue Guidelines

### Bug Reports

Include:
- **Title**: Brief, descriptive summary
- **Environment**: macOS version, Android version, device models
- **Steps to reproduce**: Numbered steps to trigger the bug
- **Expected behavior**: What should happen
- **Actual behavior**: What actually happens
- **Screenshots/logs**: If applicable

### Feature Requests

Include:
- **Title**: Brief description of the feature
- **Problem**: What problem does this solve?
- **Solution**: Your proposed solution
- **Alternatives**: Other solutions you considered
- **Additional context**: Mockups, examples, etc.

---

## Questions?

If you have questions about contributing, feel free to:
- Open a discussion on GitHub
- Ask in an issue with the `question` label

Thank you for contributing to Side Screen!
