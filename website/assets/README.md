# Website Assets

Assets cho Side Screen landing page.

---

## Files cần có

| File | Kích thước | Nguồn |
|------|------------|-------|
| `icon.png` | 128x128 | Copy từ `resources/logo/sidescreen-icon.png` và resize |
| `hero-screenshot.png` | 1920x1080 | Copy từ `resources/screenshots/hero.png` |
| `favicon.ico` | 32x32 | Generate từ icon.png |

---

## Cách tạo favicon

**Online tool:**
1. Đi tới [favicon.io](https://favicon.io/favicon-converter/)
2. Upload `icon.png`
3. Download và đặt vào thư mục này

**Hoặc dùng ImageMagick:**
```bash
convert icon.png -resize 32x32 favicon.ico
```

---

## Sau khi có đủ assets

Update `website/index.html`:
```html
<link rel="icon" href="./assets/icon.png">
```

Thay placeholder image:
```html
<img src="./assets/hero-screenshot.png" alt="Side Screen Demo">
```
