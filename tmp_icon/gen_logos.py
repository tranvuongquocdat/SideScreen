import requests
import base64
import json
import sys

API_KEY = sys.argv[1]
OUTPUT_DIR = sys.argv[2]

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

prompts = [
    {
        "name": "option1_dual_S_devices",
        "prompt": "Minimal modern app icon logo for 'Side Screen'. Two stylized letter 'S' intertwined — the left S shaped like a MacBook laptop silhouette, the right S shaped like a tablet acting as a secondary display. Clean geometric lines, flat design, gradient from deep blue (#007AFF) to teal (#34C759). White background. No text. Square icon format, rounded corners. Professional tech product logo."
    },
    {
        "name": "option2_S_mirror",
        "prompt": "Minimalist app icon logo for 'Side Screen'. A single elegant letter 'S' split vertically — left half looks like a laptop screen edge, right half looks like a tablet screen edge, with a subtle connection line between them suggesting USB-C cable. Monochrome dark navy blue with a bright accent highlight. Clean vector style, flat design. No text. Square format with rounded corners. Apple-quality design aesthetic."
    },
    {
        "name": "option3_connected_screens",
        "prompt": "Modern flat app icon for 'Side Screen'. Two overlapping 'S' shapes forming an infinity-like symbol — one S is a MacBook silhouette, the other is a tablet silhouette. They connect seamlessly suggesting screen extension. Color palette: electric blue and silver metallic gradient. Minimal, geometric, premium feel. No text. Square icon, rounded corners. Tech startup logo style."
    },
    {
        "name": "option4_abstract_SS",
        "prompt": "Ultra-clean abstract app icon for 'Side Screen'. Two parallel curved 'S' shapes side by side — resembling two screens placed next to each other. The left S is slightly larger (representing Mac), the right S slightly smaller (representing tablet). Connected by a thin horizontal line at the middle. Gradient from indigo (#5856D6) to sky blue (#5AC8FA). Flat vector design, no shadows, no text. Square format, rounded corners. Apple ecosystem design language."
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
            revised_prompt = data["data"][0].get("revised_prompt", "N/A")

            filepath = f"{OUTPUT_DIR}/{p['name']}.png"
            with open(filepath, "wb") as f:
                f.write(img_data)
            print(f"✅ Saved: {filepath}")
            print(f"   Revised prompt: {revised_prompt[:100]}...")
        else:
            print(f"❌ Error {response.status_code}: {response.text}")
    except Exception as e:
        print(f"❌ Exception: {e}")

print("\n🎉 Done! All logos generated.")
