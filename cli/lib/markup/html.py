from __future__ import annotations

from dataclasses import dataclass, field
from html.parser import HTMLParser


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.chunks: list[str] = []

    def handle_data(self, data: str) -> None:
        self.chunks.append(data)


def page_text(html: str) -> str:
    parser = TextExtractor()
    parser.feed(html)
    return "\n".join(parser.chunks)


@dataclass
class HtmlRow:
    cells: list[str]
    hrefs: list[str]
    classes: list[str] = field(default_factory=list)

    @property
    def blob(self) -> str:
        return " ".join(self.cells)


class HtmlTables(HTMLParser):
    """Collect HTML tables: cell text, first href per cell, row classes."""

    def __init__(self) -> None:
        super().__init__()
        self.tables: list[list[HtmlRow]] = []
        self._table: list[HtmlRow] | None = None
        self._cells: list[str] | None = None
        self._hrefs: list[str] | None = None
        self._classes: list[str] = []
        self._cell: list[str] = []
        self._cell_href: str | None = None
        self._in_cell = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        mapping = dict(attrs)
        name = tag.lower()
        if name == "table":
            self._table = []
        elif self._table is not None and name == "tr":
            self._cells = []
            self._hrefs = []
            self._classes = (mapping.get("class") or "").split()
        elif self._cells is not None and name in ("td", "th"):
            self._in_cell = True
            self._cell = []
            self._cell_href = None
        elif self._in_cell and name == "a":
            href = mapping.get("href")
            if href:
                self._cell_href = href

    def handle_endtag(self, tag: str) -> None:
        name = tag.lower()
        if name in ("td", "th") and self._in_cell and self._cells is not None and self._hrefs is not None:
            self._cells.append(" ".join("".join(self._cell).split()))
            self._hrefs.append(self._cell_href or "")
            self._in_cell = False
            self._cell_href = None
        elif name == "tr" and self._table is not None and self._cells is not None and self._hrefs is not None:
            if self._cells:
                self._table.append(HtmlRow(self._cells, self._hrefs, self._classes))
            self._cells = None
            self._hrefs = None
        elif name == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None

    def handle_data(self, data: str) -> None:
        if self._in_cell:
            self._cell.append(data)


def parse_tables(html: str) -> list[list[HtmlRow]]:
    parser = HtmlTables()
    parser.feed(html)
    return parser.tables


def iter_rows(html: str):
    for table in parse_tables(html):
        yield from table


class _LinkCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, str]] = []
        self._href: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() == "a":
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self._href:
            self.links.append((self._href, "".join(self._text)))
            self._href = None

    def handle_data(self, data: str) -> None:
        if self._href is not None:
            self._text.append(data)


def html_links(html: str) -> list[tuple[str, str]]:
    parser = _LinkCollector()
    parser.feed(html)
    return parser.links
