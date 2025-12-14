#!/bin/bash

# --- CẤU HÌNH ---
# Danh sách tên ứng dụng cần xóa (Tên hiển thị trong Applications)
APPS=("BetterDisplay" "Deskreen" "SplashDesktop" "Splashtop")

# Màu sắc cho thông báo
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}--- BẮT ĐẦU QUÁ TRÌNH GỠ CÀI ĐẶT ---${NC}"
echo -e "${YELLOW}Lưu ý: Script này cần quyền Admin để xóa file hệ thống.${NC}"
echo ""

# Hàm xóa file/folder
remove_path() {
    if [ -e "$1" ]; then
        echo -e "Đang xóa: $1"
        rm -rf "$1"
    fi
}

# --- BƯỚC 1: TẮT ỨNG DỤNG NẾU ĐANG CHẠY ---
echo -e "${GREEN}[1/3] Đang tắt các ứng dụng...${NC}"
for app in "${APPS[@]}"; do
    pkill -x "$app" && echo "Đã tắt $app" || echo "$app không đang chạy."
done

# --- BƯỚC 2: XÓA ỨNG DỤNG TRONG /APPLICATIONS ---
echo -e "${GREEN}[2/3] Đang xóa ứng dụng khỏi thư mục Applications...${NC}"
for app in "${APPS[@]}"; do
    remove_path "/Applications/$app.app"
    remove_path "/System/Applications/$app.app" # Kiểm tra cả thư mục hệ thống (hiếm khi cần)
done

# --- BƯỚC 3: XÓA CÁC FILE RÁC (Library, Caches, Preferences...) ---
echo -e "${GREEN}[3/3] Đang dọn dẹp file rác và cấu hình còn sót lại...${NC}"

# Danh sách các từ khóa để tìm trong Library (Dựa trên tên ứng dụng)
# BetterDisplay thường dùng: pro.betterdisplay, BetterDisplay
# Deskreen thường dùng: deskreen, io.deskreen
# Splash thường dùng: splash, splashtop

KEYWORDS=("BetterDisplay" "pro.betterdisplay" "Deskreen" "io.deskreen" "SplashDesktop" "Splashtop" "com.splashtop")

USER_LIB="$HOME/Library"
SYS_LIB="/Library"

# Các thư mục cần quét
DIRS=(
    "$USER_LIB/Application Support"
    "$USER_LIB/Caches"
    "$USER_LIB/Preferences"
    "$USER_LIB/Saved Application State"
    "$USER_LIB/Logs"
    "$USER_LIB/WebKit"
    "$SYS_LIB/Application Support"
    "$SYS_LIB/Preferences"
)

for keyword in "${KEYWORDS[@]}"; do
    echo -e "-> Đang tìm kiếm file liên quan đến: ${YELLOW}$keyword${NC}"
    
    for dir in "${DIRS[@]}"; do
        # Tìm file hoặc folder có chứa từ khóa (không phân biệt hoa thường)
        find "$dir" -maxdepth 1 -iname "*$keyword*" -print0 | while IFS= read -r -d '' file; do
            remove_path "$file"
        done
    done
done

# --- BƯỚC 4: XÓA CẤU HÌNH DISPLAY AUDIO (Nếu có) ---
# BetterDisplay hoặc Deskreen đôi khi cài driver âm thanh ảo
echo -e "${GREEN}[4/4] Kiểm tra driver âm thanh ảo...${NC}"
remove_path "/Library/Audio/Plug-Ins/HAL/BetterDisplayAudio.driver"
remove_path "/Library/Audio/Plug-Ins/HAL/DeskreenAudio.driver"

echo ""
echo -e "${GREEN}--- HOÀN TẤT! ---${NC}"
echo -e "${YELLOW}Vui lòng KHỞI ĐỘNG LẠI (Restart) máy tính để hệ thống xóa bỏ hoàn toàn các driver hiển thị ảo.${NC}"