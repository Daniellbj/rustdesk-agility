"""Gera todos os icones do RustAgility a partir de agility/logo-source.png.

Uso (na raiz do repo): python3 agility/gen_icons.py   (precisa de Pillow)
"""
from PIL import Image

src = Image.open("agility/logo-source.png").convert("RGBA")
# Recorta a margem transparente e centraliza num quadrado, com folga de 4%,
# para o "A" ocupar o maximo possivel nos tamanhos pequenos (16-32 px).
bbox = src.getbbox()
art = src.crop(bbox)
side = int(max(art.size) * 1.04)
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.paste(art, ((side - art.width) // 2, (side - art.height) // 2), art)


def png(path, size):
    square.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def ico(path, sizes):
    base = square.resize((256, 256), Image.LANCZOS)
    base.save(path, format="ICO", sizes=[(s, s) for s in sizes])


app_sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
ico("res/icon.ico", app_sizes)
ico("flutter/windows/runner/resources/app_icon.ico", app_sizes)
ico("res/tray-icon.ico", [16, 20, 24, 32, 48, 64])
png("res/icon.png", 1024)
png("res/mac-icon.png", 1024)
png("res/32x32.png", 32)
png("res/64x64.png", 64)
png("res/128x128.png", 128)
png("res/128x128@2x.png", 256)
# Interface (Flutter): icone da tela inicial e logo do topo (max 300x60).
png("flutter/assets/icon.png", 512)
png("flutter/assets/logo.png", 240)
print("ok")
