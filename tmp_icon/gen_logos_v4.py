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
    "no text, no Apple logo, no branding. Rounded square iOS/macOS app icon shape. "
    "Must be recognizable at small sizes. 1024x1024. "
    "IMPORTANT: Modern 2024 devices only — MacBook with ultra-thin bezels and a notch at the top center, "
    "iPad Pro style tablet with thin uniform bezels and rounded corners, no home button."
)

prompts = [
    {
        "name": "v4_option1",
        "prompt": f"{style_base} "
        "A modern MacBook (thin bezels, notch) on the left and a modern iPad Pro tablet (thin bezels, rounded corners) "
        "standing upright on the right as a second display. Simple white silhouettes on solid dark navy #1a1a2e background. "
        "A subtle arrow or dotted line from MacBook to tablet showing screen extension."
    },
    {
        "name": "v4_option2",
        "prompt": f"{style_base} "
        "Top-down view: a modern MacBook with notch and thin bezels, with a modern tablet (thin bezels, no home button) "
        "placed to its right side as an extended display. Both screens show a continuous blue gradient wallpaper "
        "flowing from left screen to right screen. White device outlines on dark #1C1C2E background."
    },
    {
        "name": "v4_option3",
        "prompt": f"{style_base} "
        "Front view of a modern MacBook screen (notch, thin bezels) with a modern iPad Pro (thin uniform bezels) "
        "next to it on the right, slightly overlapping. A cursor arrow icon appears between them suggesting "
        "the mouse moving from one screen to the other. Clean white outlines on solid indigo #2D2B55 background."
    },
    {
        "name": "v4_option4",
        "prompt": f"{style_base} "
        "Minimal icon: modern MacBook with notch (thin bezels) connected to a modern tablet (thin bezels, rounded corners) "
        "via a small USB-C cable at the bottom. Both devices shown as simple geometric outlines. "
        "Screens are filled with a matching light blue color to show they share one desktop. "
        "Dark background #1a1a2e, device outlines in white, screens in light blue #5AC8FA."
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
