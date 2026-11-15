#!/usr/bin/env python3
"""Тестовая библиотека demo/library: сканы, PDF, картинка, EPUB 3 (своё содержимое, без чужих книг)."""
import json, os, shutil, subprocess, sys, datetime

root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
demo = os.path.join(root, "demo")
lib = os.path.join(demo, "library")
shutil.rmtree(lib, ignore_errors=True)
os.makedirs(os.path.join(lib, ".scanreader"))

def meta(name, **kw):
    d = os.path.join(lib, ".scanreader", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump(kw, f, ensure_ascii=False, indent=2)

# 0. книга-сканы из синтетических страниц (scripts/make-demo-scan.swift) — без чужих книг
book = os.path.join(demo, "book")
shutil.rmtree(book, ignore_errors=True); os.makedirs(book)
for i in range(1, 11):
    shutil.copy(os.path.join(demo, "synthetic-page.png" if i % 2 else "code-page.png"), os.path.join(book, "%03d.png" % i))

# 1. книга-сканы (папка страниц) + её кеш распознавания
shutil.copytree(os.path.join(demo, "book"), os.path.join(lib, "React для всех (сканы)"))
# кеш распознавания не копируем: читалка распознает страницы сама
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
meta("React для всех (сканы)", title="React для всех", author="Демо-автор", collections=["Программирование"],
     progress=0.35, lastOpened=now, position={"page": 3})

# 2. PDF из страниц демо
pdf = os.path.join(lib, "Код на Swift.pdf")
subprocess.run(["/usr/bin/sips", "-s", "format", "pdf", os.path.join(demo, "code-page.png"), "--out", pdf],
               check=True, capture_output=True)
meta("Код на Swift.pdf", title="Код на Swift", author="Демо-автор", collections=["Программирование"])

# 3. одиночная картинка-скан
shutil.copy(os.path.join(demo, "synthetic-page.png"), os.path.join(lib, "Глава 2 (страница).png"))
meta("Глава 2 (страница).png", progress=1.0, lastOpened=now)

# 4. EPUB 3 (папка-пакет, как хранит Apple Books)
ep = os.path.join(lib, "Заметки о чтении.epub")
os.makedirs(os.path.join(ep, "META-INF")); os.makedirs(os.path.join(ep, "OEBPS", "images"))
open(os.path.join(ep, "mimetype"), "w").write("application/epub+zip")
open(os.path.join(ep, "META-INF", "container.xml"), "w").write(
    '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
cover = os.path.join(ep, "OEBPS", "images", "cover.png")
# обложка: scripts/make-demo-cover.swift (собранный бинарь — первым аргументом)
subprocess.run([sys.argv[1] if len(sys.argv) > 1 else "/usr/bin/true", cover], check=False)
fig = os.path.join(ep, "OEBPS", "images", "figure.png")
shutil.copy(os.path.join(demo, "synthetic-page.png"), fig)

para = ("Чтение — это разговор с автором, растянутый во времени. Хорошая книга задаёт вопросы раньше, чем мы "
        "успеваем их сформулировать, а хорошая читалка не мешает этому разговору: не отвлекает, не торопит и "
        "помнит, где мы остановились. Электронный текст позволяет менять размер шрифта, тему и поля, сохраняя "
        "структуру книги — главы, сноски, иллюстрации и примеры кода.")
chapters = [
    ("Глава 1. Зачем перечитывать", [para, para.replace("Чтение", "Перечитывание"), para]),
    ("Глава 2. Код в книгах", [para, "__CODE__", para]),
    ("Глава 3. Иллюстрации", [para, "__FIG__", para, para]),
]
code = '''import Foundation

struct Note: Codable {
    let page: Int
    let text: String
}

func load(from url: URL) throws -> [Note] {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([Note].self, from: data)
}'''
import html as H
manifest, spine, nav = [], [], []
for i, (title, body) in enumerate(chapters, 1):
    parts = []
    for b in body:
        if b == "__CODE__":
            parts.append(f'<pre><code class="language-swift">{H.escape(code)}</code></pre>')
        elif b == "__FIG__":
            parts.append('<figure><img src="images/figure.png" alt="Иллюстрация"/><figcaption>Рис. 3.1. Страница после распознавания</figcaption></figure>')
        else:
            parts.append(f"<p>{H.escape(b)}</p>")
    x = (f'<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" '
         f'xmlns:epub="http://www.idpf.org/2007/ops" lang="ru" xml:lang="ru"><head><title>{title}</title></head>'
         f'<body><section epub:type="chapter"><h1 id="c{i}">{title}</h1>{"".join(parts)}</section></body></html>')
    open(os.path.join(ep, "OEBPS", f"ch{i}.xhtml"), "w").write(x)
    manifest.append(f'<item id="ch{i}" href="ch{i}.xhtml" media-type="application/xhtml+xml"/>')
    spine.append(f'<itemref idref="ch{i}"/>')
    nav.append(f'<li><a href="ch{i}.xhtml#c{i}">{title}</a></li>')
open(os.path.join(ep, "OEBPS", "nav.xhtml"), "w").write(
    '<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Оглавление</title></head><body>'
    f'<nav epub:type="toc"><ol>{"".join(nav)}</ol></nav></body></html>')
open(os.path.join(ep, "OEBPS", "content.opf"), "w").write(
    '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">demo-notes</dc:identifier>'
    '<dc:title>Заметки о чтении</dc:title><dc:creator>Демо-автор</dc:creator><dc:language>ru</dc:language></metadata>'
    '<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    '<item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>'
    '<item id="fig" href="images/figure.png" media-type="image/png"/>' + "".join(manifest) +
    '</manifest><spine>' + "".join(spine) + '</spine></package>')
meta("Заметки о чтении.epub", collections=["Демо"])

# 5. та же книга упакованной (zip) — проверка распаковки
z = os.path.join(lib, "Заметки о чтении (zip).epub")
subprocess.run(["/bin/zsh", "-c", f'cd "{ep}" && zip -X0q "{z}" mimetype && zip -Xrq9 "{z}" META-INF OEBPS'], check=True)
print("Готово:", lib)
