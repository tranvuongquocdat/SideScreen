from PIL import Image
import os
import subprocess

BASE = "/Users/dat_macbook/Documents/2025/ý tưởng mới/Side_Screen/SideScreen"
SRC = f"{BASE}/resources/logo/main_logo.png"

img = Image.open(SRC).convert("RGBA")
w, h = img.size
print(f"Original: {w}x{h}")

# Make square by expanding to max dimension with transparent padding
size = max(w, h)
# Add 5% padding on each side
padded_size = int(size * 1.1)
square = Image.new("RGBA", (padded_size, padded_size), (0, 0, 0, 0))
offset_x = (padded_size - w) // 2
offset_y = (padded_size - h) // 2
square.paste(img, (offset_x, offset_y))
print(f"Square with padding: {padded_size}x{padded_size}")

# Save master square icon
master = f"{BASE}/resources/logo/sidescreen-icon.png"
square_1024 = square.resize((1024, 1024), Image.LANCZOS)
square_1024.save(master, "PNG")
print(f"✅ Saved master: {master}")

# --- macOS iconset ---
iconset_dir = f"{BASE}/MacHost/Resources/AppIcon.iconset"
os.makedirs(iconset_dir, exist_ok=True)

mac_sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for name, px in mac_sizes:
    resized = square.resize((px, px), Image.LANCZOS)
    # Convert to RGB with white background for macOS icons
    bg = Image.new("RGB", (px, px), (255, 255, 255))
    bg.paste(resized, mask=resized.split()[3] if resized.mode == "RGBA" else None)
    bg.save(f"{iconset_dir}/{name}", "PNG")

print(f"✅ macOS iconset: {len(mac_sizes)} sizes generated")

# Generate .icns from iconset
icns_path = f"{BASE}/MacHost/Resources/AppIcon.icns"
result = subprocess.run(
    ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
    capture_output=True, text=True
)
if result.returncode == 0:
    print(f"✅ macOS .icns generated: {icns_path}")
else:
    print(f"❌ iconutil error: {result.stderr}")

# --- Android mipmap ---
android_sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

android_res = f"{BASE}/AndroidClient/app/src/main/res"
for folder, px in android_sizes.items():
    dir_path = f"{android_res}/{folder}"
    os.makedirs(dir_path, exist_ok=True)
    resized = square.resize((px, px), Image.LANCZOS)
    # Save with transparency for Android
    resized.save(f"{dir_path}/ic_launcher.png", "PNG")

print(f"✅ Android mipmap: {len(android_sizes)} sizes generated")

print("\n🎉 All icons processed!")
