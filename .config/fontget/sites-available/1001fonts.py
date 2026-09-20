# fontget site adapter for 1001fonts.com  —  disabled until you opt in:
#     fontget sites enable 1001fonts
#
# fontget ships with no font site configured. Enabling an adapter means you have
# decided, for yourself, that fetching from 1001fonts.com is fine under that site's
# terms of use.  The adapter is plain Python: it scrapes the public HTML pages,
# so it breaks when the site changes its markup; fix it here or copy it to
# ~/.config/fontget/sites/ and edit that copy.
#
# Contract (see `fontget sites --help`): define `class Site` with
#   name, base, title_re, owns(), slug_from_url(), page_url(), exists(),
#   fetch() -> Font, search() -> (fonts, note), category() -> (title, fonts),
#   siblings(), print_categories().  Helpers such as Font, get, text, client,
#   con, err, Table, box, re, urlparse are injected by fontget when it loads
#   this file.

class Site:
    name = "1001fonts"
    base = "https://www.1001fonts.com/"
    title_re = re.compile(r"^(.*?)\s+font\s*·\s*1001 Fonts", re.I)

    @classmethod
    def owns(cls, s: str) -> bool:
        return "1001fonts" in s.lower()

    @classmethod
    def slug_from_url(cls, u) -> str | None:
        if m := re.search(r"/([a-z0-9-]+)-font\.html", u.path):
            return m.group(1)
        if m := re.search(r"/download/([a-z0-9-]+)\.zip", u.path):
            return m.group(1)
        if m := re.search(r"/download/font/([a-z0-9-]+)\.", u.path):  # st.1001fonts.net single style
            return m.group(1)
        if m := re.search(r"/typeface/([a-z0-9-]+)/", u.path):
            return m.group(1)
        return None

    @classmethod
    def page_url(cls, slug: str) -> str:
        return f"{cls.base}{slug}-font.html"

    @classmethod
    def exists(cls, slug: str) -> bool:
        return client.head(cls.page_url(slug)).status_code == 200

    @classmethod
    def parse_item(cls, li) -> Font:
        f = Font(site="1001fonts", slug="")
        if a := li.css_first("a.preview-link"):
            f.slug = a.attributes["href"].rsplit("/", 1)[-1].removesuffix("-font.html")
        if title := li.css_first(".font-title"):
            if a := title.css_first("a[rel=author]"):
                f.author, f.author_url = text(a), cls.base.rstrip("/") + a.attributes["href"]
            f.name = re.sub(r"\s*by\s+" + re.escape(f.author) + r"\s*$", "", text(title)).strip() if f.author else text(title)
        if a := li.css_first("a[class*='license-']"):
            f.license = htmlmod.unescape(a.attributes.get("title", "")).replace("<br>", " ").replace("This font is free for", "Free for")
        if a := li.css_first("a.btn-download"):
            f.download = cls.base.rstrip("/") + a.attributes["href"]
        f.download = f.download or f"{cls.base}download/{f.slug}.zip"
        return f

    @classmethod
    def entries(cls, doc: HTMLParser) -> tuple[list[Font], str]:
        total = (doc.css_first("#browsing-results") or HTMLParser("<i>")).attributes.get("data-total-items", "")
        return [f for f in map(cls.parse_item, doc.css("li.font-list-item")) if f.slug], f"{total} fonts" if total else ""

    @classmethod
    def fetch(cls, slug: str) -> Font:
        doc = get(cls.page_url(slug))
        f = Font(site="1001fonts", slug=slug)
        f.name = re.sub(r"\s+Font$", "", text(doc.css_first("h1")))
        if a := doc.css_first("a[rel=author]"):
            f.author, f.author_url = text(a), cls.base.rstrip("/") + a.attributes["href"]
        f.license = " / ".join(text(li).replace("Free for ", "") for li in doc.css("#license li.list-group-item"))
        f.license = f"Free for {f.license}" if f.license else text(doc.css_first("#license-badge"))
        if intro := text(doc.css_first("#license-intro")):
            f.extra["license note"] = intro
        for st in doc.css(".typeface-stat"):
            label = st.attributes.get("data-stat-tooltip-label", "")
            val = st.attributes.get("title") or ""
            if label == "Downloads":
                f.downloads = val
            elif label == "Date Created":
                f.first_seen = val
            elif val:
                f.extra[label.lower()] = val
        tags = [text(a).rstrip(",") for a in doc.css(".tags a")]
        f.category = ", ".join(tags)
        if tags:
            f.category_key = doc.css(".tags a")[0].attributes["href"].rsplit("/", 1)[-1].removesuffix("-fonts.html")
        f.filenames = list(dict.fromkeys(text(s) for s in doc.css("section.preview .font-title")))
        f.files = str(len(f.filenames))
        f.extra["styles"] = ", ".join(sorted({a.attributes["href"].rsplit(".", 1)[-1].upper() for a in doc.css("a.font-download-btn")}))
        if a := doc.css_first("a.charmap-toggle"):
            f.glyphs = re.sub(r"\D", "", text(a))
        if a := doc.css_first("a.btn-download[href*='/download/']"):
            f.download = cls.base.rstrip("/") + a.attributes["href"]
        f.download = f.download or f"{cls.base}download/{slug}.zip"
        if m := doc.css_first("meta[property='og:image']"):
            f.illustration = m.attributes.get("content", "")
        if d := doc.css_first("#typeface-description"):
            try:
                note = base64.b64decode(d.attributes.get("data-m", "")).decode("utf-8", "replace")
            except Exception:
                note = text(d)
            note = re.sub(r"\[url=([^\]]+)\]([^\[]*)\[/url\]", r"\2 (\1)", note)
            f.note = re.sub(r"\n{3,}", "\n\n", re.sub(r"\[/?[a-z]+\]", "", note)).strip()
        return f

    @classmethod
    def search(cls, query: str, page: int = 1) -> tuple[list[Font], str]:
        return cls.entries(get(f"{cls.base}search.html", search=query, page=page))

    @classmethod
    def category(cls, cat: str, page: int = 1) -> tuple[str, list[Font]]:
        slug = re.sub(r"[^a-z0-9+]+", "-", cat.lower().strip()).strip("-").removesuffix("-fonts")
        doc = get(f"{cls.base}{slug}-fonts.html", page=page)
        fonts, total = cls.entries(doc)
        title = text(doc.css_first("h1"))
        for f in fonts:
            f.category, f.category_key = f.category or title.removesuffix(" Fonts"), f.category_key or slug
        return f"{title} ({total})", fonts

    @classmethod
    def siblings(cls, f: Font) -> list[Font]:
        return cls.category(f.category_key)[1] if f.category_key else []

    @classmethod
    def print_categories(cls):
        doc = get(cls.base)
        t = Table(box=box.SIMPLE, padding=(0, 1), title="1001fonts.com  (<slug>-fonts.html)")
        t.add_column("group", style="bold"); t.add_column("categories")
        for li in doc.css("li.category"):
            cats = [a.attributes["href"].rsplit("/", 1)[-1].removesuffix("-fonts.html") for a in li.css("a")]
            t.add_row(text(li.css_first(".category-label")), "  ".join(cats))
        con.print(t)
