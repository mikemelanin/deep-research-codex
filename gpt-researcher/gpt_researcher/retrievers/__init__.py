"""Lazy retriever exports.

The local slim install only needs Tavily, but importing this package used to
eagerly import every optional retriever and their heavy dependencies.
"""

_EXPORTS = {
    "ArxivSearch": ".arxiv.arxiv",
    "BingSearch": ".bing.bing",
    "BoChaSearch": ".bocha.bocha",
    "CustomRetriever": ".custom.custom",
    "Duckduckgo": ".duckduckgo.duckduckgo",
    "ExaSearch": ".exa.exa",
    "GoogleSearch": ".google.google",
    "MCPRetriever": ".mcp",
    "PubMedCentralSearch": ".pubmed_central.pubmed_central",
    "SearchApiSearch": ".searchapi.searchapi",
    "SemanticScholarSearch": ".semantic_scholar.semantic_scholar",
    "SerpApiSearch": ".serpapi.serpapi",
    "SerperSearch": ".serper.serper",
    "SearxSearch": ".searx.searx",
    "TavilySearch": ".tavily.tavily_search",
    "XquikSearch": ".xquik.xquik",
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
