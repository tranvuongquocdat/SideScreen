import requests
import base64
import sys

API_KEY = sys.argv[1]
OUTPUT_DIR = sys.argv[2]

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

style_base = (
    "Simple flat app icon, minimal design, clean shapes, solid colors, "
    "no gradients or at most one subtle gradient, no glow effects, no sparkles, "
    "no 3D, no shadows, no text. Rounded square iOS app icon shape. "
    "Must be recognizable at small sizes like 64x64px. 1024x1024."
)

prompts = [
    {
        "name": "v3_option1",
        "prompt": f"{style_base} "
        "A MacBook screen on the left with a tablet screen on the right, side by side, "
        "connected by a simple thin line or arrow pointing right. "
        "White/light gray devices on a deep blue background. Very simple silhouettes only."
    },
    {
        "name": "v3_option2",
        "prompt": f"{style_base} "
        "A simple laptop silhouette with a plus sign and a tablet silhouette next to it. "
        "Concept: extending your laptop with a tablet as second monitor. "
        "White icons on dark indigo background. Extremely minimal, like a system settings icon."
    },
    {
        "name": "v3_option3",
        "prompt": f"{style_base} "
        "Side view: a MacBook laptop on the left, a tablet standing upright on the right as a secondary display. "
        "Both shown as simple white outlines/silhouettes on a solid dark purple background. "
        "A small USB-C cable connects them at the bottom. Icon style like Apple's own system icons."
    },
    {
        "name": "v3_option4",
        "prompt": f"{style_base} "
        "Two rectangles side by side — left one is wider (laptop screen), right one is narrower (tablet). "
        "They share a continuous desktop wallpaper flowing from left to right, "
        "suggesting the screen extends onto the tablet. "
        "Solid dark background, screens are white with a subtle blue tint. Ultra simple."
    }
]

for i, p in enumerate(prompts):
    print(f"\n🎨 Generating {p['name']}...")
    try:
        response = requests.post(
            "https://api.openai.com/v1/images/generations",
            headers=headers,
            json={
                "model": "dall-e-3",
                "prompt": p["prompt"],
                "n": 1,
                "size": "1024x1024",
                "quality": "hd",
                "response_format": "b64_json"
            },
            timeout=120
        )

        if response.status_code == 200:
            data = response.json()
            img_data = base64.b64decode(data["data"][0]["b64_json"])
            filepath = f"{OUTPUT_DIR}/{p['name']}.png"
            with open(filepath, "wb") as f:
                f.write(img_data)
            print(f"✅ Saved: {filepath}")
        else:
            print(f"❌ Error {response.status_code}: {response.text}")
    except Exception as e:
        print(f"❌ Exception: {e}")

print("\n🎉 Done!")
