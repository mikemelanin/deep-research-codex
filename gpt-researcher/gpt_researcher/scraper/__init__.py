"""Lazy scraper exports.

The local slim install uses the BeautifulSoup scraper. Optional scrapers such
as PDF, browser, arxiv, FireCrawl, and WebBaseLoader are imported only when
selected.
"""

_EXPORTS = {
    "ArxivScraper": ".arxiv.arxiv",
    "BeautifulSoupScraper": ".beautiful_soup.beautiful_soup",
    "BrowserScraper": ".browser.browser",
    "FireCrawl": ".firecrawl.firecrawl",
    "NoDriverScraper": ".browser.nodriver_scraper",
    "PyMuPDFScraper": ".pymupdf.pymupdf",
    "Scraper": ".scraper",
    "TavilyExtract": ".tavily_extract.tavily_extract",
    "WebBaseLoaderScraper": ".web_base_loader.web_base_loader",
}

__all__ = list(_EXPORTS)


def __getattr__(name):
    if name not in _EXPORTS:
        raise AttributeError(name)

    from importlib import import_module

    module = import_module(_EXPORTS[name], __name__)
    value = getattr(module, name)
    globals()[name] = value
    return value
