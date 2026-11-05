"""Deterministic paper backing and tight thumbnail for transparent generated artwork."""
from PIL import Image, ImageChops, ImageFilter, ImageOps


def kiss_cut_sticker(artwork):
    artwork = ImageOps.contain(artwork, (660, 660), Image.Resampling.LANCZOS)
    ink = Image.new('RGBA', (1024, 1024))
    ink.alpha_composite(artwork, ((1024 - artwork.width) // 2, (1024 - artwork.height) // 2))
    clean_alpha = ink.getchannel('A').point(lambda value: 255 if value > 20 else 0)
    field = clean_alpha.filter(ImageFilter.MaxFilter(29)).filter(ImageFilter.GaussianBlur(9))
    backing = field.point(lambda value: min(255, max(0, (value - 28) * 10)))

    shadow_alpha = backing.filter(ImageFilter.GaussianBlur(10)).point(lambda value: round(value * 26 / 255))
    shadow = Image.new('RGBA', ink.size, (22, 21, 20, 0))
    shadow.putalpha(shadow_alpha)
    picture = Image.new('RGBA', ink.size)
    picture.alpha_composite(shadow, (0, 5))
    paper = Image.new('RGBA', ink.size, '#FAF8F2')
    paper.putalpha(backing)
    picture.alpha_composite(paper)

    # An inset one-pixel cut edge follows the same smooth silhouette as the paper.
    edge_alpha = ImageChops.subtract(backing, backing.filter(ImageFilter.MinFilter(3)))
    edge = Image.new('RGBA', ink.size, (22, 21, 20, 0))
    edge.putalpha(edge_alpha.point(lambda value: round(value * 30 / 255)))
    picture.alpha_composite(edge)
    picture.alpha_composite(ink)

    closeup = ImageOps.contain(picture.crop(picture.getchannel('A').getbbox()),
                              (468, 468), Image.Resampling.LANCZOS)
    thumbnail = Image.new('RGBA', (512, 512))
    thumbnail.alpha_composite(closeup, ((512 - closeup.width) // 2, (512 - closeup.height) // 2))
    return picture, thumbnail
