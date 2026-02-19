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
    "Premium app icon, dark navy/purple background with deep gradient, "
    "3D glossy depth effect, inner glow and luminous warm accents, "
    "rounded square icon shape like iOS/macOS app icons, "
    "ultra-polished, modern, minimalist. No text whatsoever. "
    "Style reference: dark purple-violet gradient with glowing golden/warm light elements, "
    "layered depth with subtle shadows, premium tech product aesthetic. "
    "1024x1024 square icon."
)

prompts = [
    {
        "name": "v2_option1_dual_screens",
        "prompt": f"App icon for a screen-extending app called Side Screen. {style_base} "
        "The icon shows two screens side by side — a larger MacBook display on the left and a smaller tablet display on the right, "
        "connected by a glowing light beam or energy arc between them. The screens have a subtle glow emanating from them. "
        "Deep indigo to purple gradient background with warm golden glow accents."
    },
    {
        "name": "v2_option2_extend_arrow",
        "prompt": f"App icon for a screen-extending app. {style_base} "
        "Abstract design: a single monitor/screen shape that splits and extends to the right, "
        "as if the display is stretching outward into a second screen. A flowing, glowing energy trail "
        "connects the two halves. Deep purple-to-blue gradient with warm amber/golden glow on the extending part. "
        "Layered 3D depth effect."
    },
    {
        "name": "v2_option3_portal",
        "prompt": f"App icon for a display extension app. {style_base} "
        "A glowing rectangular portal or window frame — the left edge looks like a laptop screen bezel, "
        "the right edge morphs into a tablet bezel. Inside the portal is a bright warm glow suggesting "
        "the screen content flowing through. Deep dark purple background, the portal frame has "
        "an iridescent blue-purple-pink shimmer. Ethereal and premium."
    },
    {
        "name": "v2_option4_mirror_reflect",
        "prompt": f"App icon for a second display app. {style_base} "
        "Two overlapping rounded rectangles representing screens — one slightly larger (Mac), one slightly smaller (tablet), "
        "offset diagonally. Where they overlap there is a bright warm golden glow. "
        "The screens have thin glowing edges. Deep space purple-indigo background with "
        "luminous warm accent where screens meet. Clean geometric, layered 3D depth."
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
