# Screenshots Guide

Hướng dẫn capture screenshots đẹp cho Side Screen.

---

## Danh sách screenshots cần có

| File | Kích thước | Mô tả | Dùng ở đâu |
|------|------------|-------|------------|
| `hero.png` | 1920x1080 | Demo tổng quan app | README, Website hero |
| `settings-mac.png` | 800x600 | macOS Settings window | README Features |
| `settings-android.png` | 400x800 | Android Settings panel | README Features |
| `connection-steps.png` | 1200x400 | 3 bước kết nối | README Usage |

---

## Hướng dẫn capture

### 1. Hero Shot (Quan trọng nhất)

**Mục tiêu:** Thể hiện app đang hoạt động với Mac và tablet

**Setup:**
- Đặt MacBook và tablet cạnh nhau trên bàn sạch
- Tablet hiển thị content từ Mac (kéo một cửa sổ sang)
- Background: bàn gỗ đơn giản hoặc màu đen solid

**Góc chụp:**
- Góc 30-45 độ từ trên xuống
- Chụp từ phía trước, hơi lệch về bên trái
- Đảm bảo thấy cả 2 màn hình rõ ràng

**Tools:**
- iPhone camera với Portrait mode
- Hoặc DSLR nếu có
- Ánh sáng tự nhiên từ cửa sổ

**Post-processing:**
- Crop ratio 16:9
- Tăng contrast nhẹ
- Làm nổi màn hình (dodge/burn)

---

### 2. Settings Window (macOS)

**Cách capture:**
```bash
# Cách 1: macOS built-in (có shadow đẹp)
# Nhấn Cmd+Shift+4, sau đó Space, click vào window

# Cách 2: Không shadow
screencapture -o -W settings-mac.png
```

**Tools recommended:**
- [Shottr](https://shottr.cc/) - Free, có rounded corners
- [CleanShot X](https://cleanshot.com/) - Paid, rất pro

**Tips:**
- Mở Settings window với các options đã set sẵn
- Chọn một resolution đẹp (1920x1200)
- Gaming boost ON để có màu accent

---

### 3. Android Settings Panel

**Cách capture:**
```bash
# Qua ADB
adb shell screencap -p /sdcard/screenshot.png
adb pull /sdcard/screenshot.png settings-android.png

# Hoặc dùng Android Studio Device Mirror
```

**Thêm device frame:**
- [Device Frames](https://deviceframes.com/) - Online tool
- [Previewed](https://previewed.app/) - macOS app
- Hoặc dùng Figma templates

**Tips:**
- Mở settings panel (tap vào nút Settings)
- Stats overlay hiển thị (60 FPS, 20 Mbps)
- Full screen video đang chạy phía sau

---

### 4. Connection Steps

**Concept:** 3 bước ghép ngang: Connect USB → Run Command → Tap Connect

**Tạo composite:**
1. Capture 3 screenshots riêng
2. Dùng Figma/Canva ghép lại
3. Thêm số thứ tự (1, 2, 3) với circles
4. Thêm arrows giữa các bước

**Layout:**
```
[Step 1: USB connected] → [Step 2: Terminal] → [Step 3: App Connect button]
```

---

## Màu sắc & Style

**Palette:**
- Primary: #007AFF (Apple Blue)
- Background: #FAFAFA hoặc #1D1D1F (dark)
- Text overlay: White với shadow

**Font cho annotations:**
- SF Pro (macOS system font)
- Weight: Medium hoặc Semibold

---

## Sau khi capture

1. Đặt file vào thư mục này: `resources/screenshots/`
2. Đảm bảo tên file đúng như trong README.md
3. Commit và push

---

## Reference

Xem các app tương tự để lấy cảm hứng:
- Duet Display
- Luna Display
- Sidecar (Apple)
- Deskreen

Lưu ý: Capture style của mình, không copy trực tiếp.
