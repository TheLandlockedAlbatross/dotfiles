# fontget site adapter for fontmeme.com  —  disabled until you opt in:
#     fontget sites enable fontmeme
#
# fontget ships with no font site configured. Enabling an adapter means you have
# decided, for yourself, that fetching from fontmeme.com is fine under that site's
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
    name = "fontmeme"
    base = "https://fontmeme.com/"
    title_re = re.compile(r"^(.*?)\s+Font Download\b", re.I)  # Firefox title carries no host

    @classmethod
    def owns(cls, s: str) -> bool:
        return "fontmeme.com" in s.lower()

    @classmethod
    def slug_from_url(cls, u) -> str | None:
        if m := re.search(r"/fonts/([a-z0-9-]+)-font/?", u.path):
            return m.group(1)
        if m := re.search(r"/fonts/download/\d+/([a-z0-9-]+)\.zip", u.path):
            return m.group(1)
        return None

    @classmethod
    def page_url(cls, slug: str) -> str:
        return f"{cls.base}fonts/{slug}-font/"

    @classmethod
    def exists(cls, slug: str) -> bool:
        return client.head(cls.page_url(slug)).status_code == 200

    @classmethod
    def tag_slug(cls, href: str) -> str:
        return href.rstrip("/").rsplit("/", 1)[-1].removesuffix("-fonts-collection")

    @classmethod
    def parse_item(cls, w) -> Font:
        f = Font(site="fontmeme", slug="")
        if a := w.css_first(".fontPreviewTitle a"):
            f.slug, f.name = cls.slug_from_url(urlparse(a.attributes["href"])) or "", text(a)
        if a := w.css_first(".fontdesigners a"):
            f.author, f.author_url = text(a), cls.base.rstrip("/") + a.attributes["href"]
        if st := text(w.css_first(".fontstyles")):
            f.files = str(int(st.strip("+ ")) + 1) if st.strip("+ ").isdigit() else st
        tags = [a for a in w.css(".fontTopCategories a") if text(a)]
        f.category = ", ".join(text(a) for a in tags)
        if tags:
            f.category_key = cls.tag_slug(tags[0].attributes["href"])
        f.license = text(w.css_first(".license"))
        if d := w.css_first(".downloadButton[data-id]"):
            f.download = f"{cls.base}fonts/download/{d.attributes['data-id']}/{f.slug}.zip"
        return f

    @classmethod
    def entries(cls, doc: HTMLParser) -> list[Font]:
        return [f for f in map(cls.parse_item, doc.css(".fontPreviewWrapper")) if f.slug]

    @classmethod
    def fetch(cls, slug: str) -> Font:
        doc = get(cls.page_url(slug))
        f = Font(site="fontmeme", slug=slug)
        f.name = re.sub(r"\s+Font$", "", text(doc.css_first("h1")))
        for tr in doc.css(".fontDesigner tr"):
            cells = tr.css("td")
            if len(cells) < 2:
                continue
            key, val = text(cells[0]).rstrip(":"), cells[1]
            if key == "license type":
                f.license = text(val)
            elif key == "designer":
                f.author = text(val)
                if a := val.css_first("a"):
                    f.author_url = cls.base.rstrip("/") + a.attributes["href"]
            elif key == "website":
                f.extra["website"] = text(val)
            elif key == "font tags":
                tags = [a for a in val.css("a") if text(a)]
                f.category = ", ".join(text(a) for a in tags)
                if tags:
                    f.category_key = cls.tag_slug(tags[0].attributes["href"])
            elif key == "downloads":
                f.downloads = text(val)
        rows = [tr.css("td") for tr in doc.css("table tr") if len(tr.css("td")) == 3]
        f.filenames = [text(c[0]) for c in rows if re.search(r"\.(ttf|otf|ttc)$", text(c[0]), re.I)]
        f.files = str(len(f.filenames))
        f.size = ", ".join(text(c[1]) for c in rows) if len(rows) == 1 else ""
        f.glyphs = ", ".join(text(c[2]).split("|")[0].strip() for c in rows)
        if img := doc.css_first("img[src*='-font-preview.png']"):
            f.illustration = img.attributes.get("src", "")
        if d := doc.css_first(".downloadButton[data-id]"):
            f.download = f"{cls.base}fonts/download/{d.attributes['data-id']}/{slug}.zip"
        if not f.download:
            err.print(f"{cls.page_url(slug)} has no download button")
            raise typer.Exit(1)
        return f

    @classmethod
    def search(cls, query: str, page: int = 1) -> tuple[list[Font], str]:
        if page > 1:
            return [], ""  # fontmeme search is a single page
        return cls.entries(get(f"{cls.base}fonts/search.html", q=query)), ""

    @classmethod
    def category(cls, cat: str, page: int = 1) -> tuple[str, list[Font]]:
        want = cat.lower().strip().removesuffix("-fonts-collection").removesuffix(" fonts")
        for slug in dict.fromkeys([re.sub(r"[^a-z0-9]", "", want), re.sub(r"[^a-z0-9]+", "-", want).strip("-")]):
            r = client.get(f"{cls.base}fonts/{slug}-fonts-collection/{page}/")
            if r.status_code == 200:
                break
        else:
            err.print(f"no fontmeme collection for {cat!r}; see `fontget categories -s fontmeme`")
            raise typer.Exit(1)
        doc = HTMLParser(r.text)
        title = text(doc.css_first("title")).split("|")[0].strip()
        fonts = cls.entries(doc)
        for f in fonts:
            f.category_key = f.category_key or slug
        return title, fonts

    @classmethod
    def siblings(cls, f: Font) -> list[Font]:
        return cls.category(f.category_key)[1] if f.category_key else []

    @classmethod
    def print_categories(cls):
        doc = get(f"{cls.base}fonts/")
        t = Table(box=box.SIMPLE, padding=(0, 1), title="fontmeme.com  (fonts/<tag>-fonts-collection/; 240+ more tags at fonts/tags.html)")
        t.add_column("group", style="bold"); t.add_column("categories")
        group, cats = "", []
        for a in doc.css(".tagcloud a"):
            if "subtag" in (a.attributes.get("class") or ""):
                if group:
                    t.add_row(group, "  ".join(cats))
                group, cats = text(a), []
            elif "-fonts-collection" in a.attributes.get("href", ""):
                cats.append(cls.tag_slug(a.attributes["href"]))
        if group:
            t.add_row(group, "  ".join(cats))
        con.print(t)
