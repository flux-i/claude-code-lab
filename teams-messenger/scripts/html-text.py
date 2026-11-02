#!/usr/bin/env python3
"""Decode inert Teams message HTML without a browser or network access."""
import json
import re
import sys
from html.parser import HTMLParser

BLOCKS = {"p", "div", "li", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"}

class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.stack = []
        self.skip = 0
        self.after_block = False

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style"}:
            self.skip += 1
        if self.skip:
            return
        if tag in BLOCKS:
            if self.parts and (self.after_block or self.stack):
                self.parts.append("\n")
            self.stack.append([tag, len(self.parts)])
            self.after_block = False
        elif tag == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if self.skip:
            if tag in {"script", "style"}:
                self.skip -= 1
            return
        if tag in BLOCKS and self.stack:
            name, start = self.stack.pop()
            segment = "".join(self.parts[start:])
            if segment in {"\n", "\u00a0"}:
                del self.parts[start:]
            self.after_block = True

    def handle_data(self, data):
        if self.skip:
            return
        if self.after_block and data.strip():
            self.parts.append("\n")
            self.after_block = False
        self.parts.append(data)

    def value(self):
        return "".join(self.parts).replace("\r\n", "\n").replace("\u00a0", " ")

def decode(body):
    parser = Text()
    parser.feed(re.sub(r"(<br\s*/?>)\r?\n", r"\1", body, flags=re.I))
    return parser.value()

if __name__ == "__main__":
    json.dump([decode(body) for body in json.load(sys.stdin)], sys.stdout, ensure_ascii=False)
