# fontget site adapter for dafont.com  —  disabled until you opt in:
#     fontget sites enable dafont
#
# fontget ships with no font site configured. Enabling an adapter means you have
# decided, for yourself, that fetching from dafont.com is fine under that site's
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
    name = "dafont"
    base = "https://www.dafont.com/"
    title_re = re.compile(r"^(.*?)\s+font\s*\|\s*dafont\.com", re.I)
    # theme.php?cat= ids, verified against the site 2026-09-13.
    CATEGORIES: dict[int, tuple[str, str]] = {
        101: ("Fancy", "Cartoon"), 102: ("Fancy", "Comic"), 103: ("Fancy", "Groovy"),
        104: ("Fancy", "Old School"), 105: ("Fancy", "Curly"), 106: ("Fancy", "Western"),
        107: ("Fancy", "Eroded"), 108: ("Fancy", "Distorted"), 109: ("Fancy", "Destroy"),
        110: ("Fancy", "Horror"), 111: ("Fancy", "Fire, Ice"), 112: ("Fancy", "Decorative"),
        113: ("Fancy", "Typewriter"), 114: ("Fancy", "Stencil, Army"), 115: ("Fancy", "Retro"),
        116: ("Fancy", "Initials"), 117: ("Fancy", "Grid"), 118: ("Fancy", "Various"),
        201: ("Foreign look", "Chinese, Jpn"), 202: ("Foreign look", "Arabic"),
        203: ("Foreign look", "Mexican"), 204: ("Foreign look", "Roman, Greek"),
        205: ("Foreign look", "Russian"), 206: ("Foreign look", "Various"),
        301: ("Techno", "Square"), 302: ("Techno", "LCD"), 303: ("Techno", "Sci-fi"),
        304: ("Techno", "Various"),
        401: ("Gothic", "Medieval"), 402: ("Gothic", "Modern"), 403: ("Gothic", "Celtic"),
        404: ("Gothic", "Initials"),
        501: ("Basic", "Sans serif"), 502: ("Basic", "Serif"), 503: ("Basic", "Fixed width"),
        504: ("Basic", "Various"),
        601: ("Script", "Calligraphy"), 602: ("Script", "School"), 603: ("Script", "Handwritten"),
        604: ("Script", "Brush"), 605: ("Script", "Trash"), 606: ("Script", "Graffiti"),
        607: ("Script", "Old School"), 608: ("Script", "Various"),
        701: ("Dingbats", "Alien"), 702: ("Dingbats", "Animals"), 703: ("Dingbats", "Asian"),
        704: ("Dingbats", "Ancient"), 705: ("Dingbats", "Runes, Elvish"), 706: ("Dingbats", "Esoteric"),
        707: ("Dingbats", "Fantastic"), 708: ("Dingbats", "Horror"), 709: ("Dingbats", "Games"),
        710: ("Dingbats", "Shapes"), 711: ("Dingbats", "Bar Code"), 712: ("Dingbats", "Nature"),
        713: ("Dingbats", "Sport"), 714: ("Dingbats", "Heads"), 715: ("Dingbats", "Kids"),
        716: ("Dingbats", "TV, Movie"), 717: ("Dingbats", "Logos"), 718: ("Dingbats", "Sexy"),
        719: ("Dingbats", "Army"), 720: ("Dingbats", "Music"), 721: ("Dingbats", "Various"),
        801: ("Holiday", "Valentine"), 802: ("Holiday", "Easter"), 803: ("Holiday", "Halloween"),
        804: ("Holiday", "Christmas"), 805: ("Holiday", "Various"),
    }

    @classmethod
    def owns(cls, s: str) -> bool:
        return "dafont.com" in s.lower()

    @classmethod
    def slug_from_url(cls, u) -> str | None:
        if q := parse_qs(u.query).get("f"):
            return q[0]
        if m := re.search(r"([A-Za-z0-9_-]+)\.(?:font|charmap)", u.path):
            return m.group(1).lower()
        return None

    @classmethod
    def page_url(cls, slug: str) -> str:
        return f"{cls.base}{slug}.font"

    @classmethod
    def exists(cls, slug: str) -> bool:
        return client.head(cls.page_url(slug)).status_code == 200

    @classmethod
    def cat_name(cls, cid) -> str:
        return " > ".join(cls.CATEGORIES[cid]) if cid in cls.CATEGORIES else "?"

    @classmethod
    def parse_entry(cls, lv1left, lv1right, lv2right, dlbox, preview, slug: str = "") -> Font:
        f = Font(site="dafont", slug=slug)
        for holder in (lv1left, preview):
            if holder and (a := holder.css_first("a[href$='.font']")):
                f.slug = a.attributes["href"].rsplit("/", 1)[-1][:-5].lower()
                break
        if lv1left:
            for span in lv1left.css("span.contain"):
                f.extra[span.attributes.get("title", "").lower()] = "yes"
            # search pages wrap only the matched word in <span class="highlight">, so take the whole
            # left cell minus the accent/euro markers and the "by author" tail
            head = re.split(r"\s+by\s+", text(lv1left), maxsplit=1)[0]
            f.name = text(lv1left.css_first("strong")) or re.sub(r"\s*[à€]\s*", " ", head).strip()
            if a := lv1left.css_first("a[href*='.d']"):
                f.author, f.author_url = text(a), cls.base + a.attributes["href"]
            if a := lv1left.css_first("a.tdn[target=_blank]"):
                f.author_url = a.attributes.get("href", f.author_url)
        if lv1right and (a := lv1right.css_first("a[href*='theme.php?cat=']")):
            f.category_key = a.attributes["href"].rsplit("=", 1)[1]
            f.category = cls.cat_name(int(f.category_key))
        if lv2right:
            f.downloads = text(lv2right.css_first("span.light"))
            f.license = text(lv2right.css_first("a.help"))
            if c := text(lv2right.css_first("a[href*='font-comment']")):
                f.extra["comments"] = f"{c}  {cls.base}font-comment.php?file={f.slug}"
            if m := re.search(r"(\d+) font files?", text(lv2right)):
                f.files = m.group(1)
        if dlbox and (a := dlbox.css_first("a.dl")):
            f.size = a.attributes.get("title", "")
            href = a.attributes.get("href", "")
            f.download = "https:" + href if href.startswith("//") else href
        f.download = f.download or f"https://dl.dafont.com/dl/?f={f.slug}"
        return f

    @classmethod
    def entries(cls, doc: HTMLParser, category_key: str = "") -> list[Font]:
        out = []
        for lv1left in doc.css("div.lv1left"):
            n, sib = lv1left, []
            while n := n.next:
                if n.tag == "div" and "lv1left" in (n.attributes.get("class") or ""):
                    break
                sib.append(n)
            pick = lambda c: next((s for s in sib if s.tag == "div" and c in (s.attributes.get("class") or "").split()), None)
            f = cls.parse_entry(lv1left, pick("lv1right"), pick("lv2right"), pick("dlbox"), pick("preview"))
            if not f.category and category_key:  # category pages leave the breadcrumb blank
                f.category_key, f.category = category_key, cls.cat_name(int(category_key))
            if f.slug:
                out.append(f)
        return out

    @classmethod
    def fetch(cls, slug: str) -> Font:
        doc = get(cls.page_url(slug))
        lv1left = doc.css_first("div.lv1left")
        if not lv1left:
            err.print(f"{cls.page_url(slug)} is not a font page")
            raise typer.Exit(1)
        f = cls.parse_entry(lv1left, doc.css_first("div.lv1right"), doc.css_first("div.lv2right"),
                            doc.css_first("div.dlbox"), None, slug)
        f.slug = slug
        f.filenames = [text(b) for b in doc.css("div[style*='linear-gradient'] > b")]
        f.files = f.files or str(len(f.filenames))
        for d in doc.css("div.dfsmall"):
            if (t := text(d)).startswith("First seen on DaFont:"):
                f.first_seen = t.split(":", 1)[1].strip()
        if a := doc.css_first("a[href$='.charmap']"):
            if m := re.search(r"\((\d+)\)", text(a)):
                f.glyphs = m.group(1)
        if img := doc.css_first("img[src*='/img/illustration/']"):
            f.illustration = cls.base.rstrip("/") + img.attributes["src"]
        for d in doc.css("div"):
            if text(d) == "Note of the author" and d.next:
                raw = re.sub(r"<br\s*/?>", "\n", d.next.html or "")
                lines = [l.strip() for l in htmlmod.unescape(re.sub(r"<[^>]+>", "", raw)).splitlines()]
                f.note = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
                break
        return f

    @classmethod
    def search(cls, query: str, page: int = 1) -> tuple[list[Font], str]:
        doc = get(f"{cls.base}search.php", q=query, page=page)
        m = re.search(r"(\d[\d,]*) fonts? on DaFont", doc.text())
        return cls.entries(doc), (m.group(0) if m else "")

    @classmethod
    def category(cls, cat: str, page: int = 1) -> tuple[str, list[Font]]:
        if cat.isdigit():
            cid = int(cat)
        else:
            hits = [i for i, (_, sub) in cls.CATEGORIES.items() if cat.lower() in sub.lower()]
            if len(hits) != 1:
                err.print(f"dafont category {cat!r} matches {len(hits)} entries; see `fontget categories -s dafont`")
                raise typer.Exit(2)
            cid = hits[0]
        doc = get(f"{cls.base}theme.php", cat=cid, page=page)
        return cls.cat_name(cid), cls.entries(doc, str(cid))

    @classmethod
    def siblings(cls, f: Font) -> list[Font]:
        return cls.entries(get(f"{cls.base}theme.php", cat=f.category_key), f.category_key) if f.category_key else []

    @classmethod
    def print_categories(cls):
        t = Table(box=box.SIMPLE, padding=(0, 1), title="dafont.com  (theme.php?cat=ID)")
        t.add_column("id", style="bold"); t.add_column("category"); t.add_column("sub")
        for cid, (main, sub) in cls.CATEGORIES.items():
            t.add_row(str(cid), main, sub)
        con.print(t)
