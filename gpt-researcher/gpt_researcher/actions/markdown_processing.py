import re
from typing import Dict, List


HEADER_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)


def extract_headers(markdown_text: str) -> List[Dict]:
    """Extract nested markdown headers directly from source markdown."""
    headers: List[Dict] = []
    stack: List[Dict] = []

    for match in HEADER_RE.finditer(markdown_text):
        level = len(match.group(1))
        header = {
            "level": level,
            "text": match.group(2).strip(),
        }

        while stack and stack[-1]["level"] >= level:
            stack.pop()

        if stack:
            stack[-1].setdefault("children", []).append(header)
        else:
            headers.append(header)

        stack.append(header)

    return headers


def extract_sections(markdown_text: str) -> List[Dict[str, str]]:
    """Extract markdown sections by headers without importing the markdown package."""
    matches = list(HEADER_RE.finditer(markdown_text))
    sections: List[Dict[str, str]] = []

    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(markdown_text)
        content = markdown_text[start:end].strip()
        if content:
            sections.append(
                {
                    "section_title": match.group(2).strip(),
                    "written_content": content,
                }
            )

    return sections


def table_of_contents(markdown_text: str) -> str:
    """Generate a simple markdown table of contents from headers."""

    def generate_table_of_contents(headers, indent_level=0):
        toc = ""
        for header in headers:
            toc += " " * (indent_level * 4) + "- " + header["text"] + "\n"
            if "children" in header:
                toc += generate_table_of_contents(header["children"], indent_level + 1)
        return toc

    try:
        headers = extract_headers(markdown_text)
        toc = "## Table of Contents\n\n" + generate_table_of_contents(headers)
        return toc
    except Exception as e:
        print("table_of_contents Exception : ", e)
        return markdown_text


def add_references(report_markdown: str, visited_urls: set) -> str:
    """Append visited URLs as markdown references."""
    try:
        url_markdown = "\n\n\n## References\n\n"
        url_markdown += "".join(f"- [{url}]({url})\n" for url in visited_urls)
        updated_markdown_report = report_markdown + url_markdown
        return updated_markdown_report
    except Exception as e:
        print(f"Encountered exception in adding source urls : {e}")
        return report_markdown
