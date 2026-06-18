"""Retriever factory and utilities for GPT Researcher.

This module provides functions to instantiate and manage various
search retriever implementations.
"""

from importlib import import_module


_RETRIEVER_EXPORTS = {
    "google": ("gpt_researcher.retrievers.google.google", "GoogleSearch"),
    "searx": ("gpt_researcher.retrievers.searx.searx", "SearxSearch"),
    "searchapi": ("gpt_researcher.retrievers.searchapi.searchapi", "SearchApiSearch"),
    "serpapi": ("gpt_researcher.retrievers.serpapi.serpapi", "SerpApiSearch"),
    "serper": ("gpt_researcher.retrievers.serper.serper", "SerperSearch"),
    "duckduckgo": ("gpt_researcher.retrievers.duckduckgo.duckduckgo", "Duckduckgo"),
    "bing": ("gpt_researcher.retrievers.bing.bing", "BingSearch"),
    "bocha": ("gpt_researcher.retrievers.bocha.bocha", "BoChaSearch"),
    "arxiv": ("gpt_researcher.retrievers.arxiv.arxiv", "ArxivSearch"),
    "tavily": ("gpt_researcher.retrievers.tavily.tavily_search", "TavilySearch"),
    "exa": ("gpt_researcher.retrievers.exa.exa", "ExaSearch"),
    "semantic_scholar": (
        "gpt_researcher.retrievers.semantic_scholar.semantic_scholar",
        "SemanticScholarSearch",
    ),
    "pubmed_central": (
        "gpt_researcher.retrievers.pubmed_central.pubmed_central",
        "PubMedCentralSearch",
    ),
    "custom": ("gpt_researcher.retrievers.custom.custom", "CustomRetriever"),
    "mcp": ("gpt_researcher.retrievers.mcp", "MCPRetriever"),
    "xquik": ("gpt_researcher.retrievers.xquik.xquik", "XquikSearch"),
}


def get_retriever(retriever: str):
    """Get a retriever class by name.

    Args:
        retriever: The name of the retriever to get (e.g., 'google', 'tavily', 'duckduckgo').

    Returns:
        The retriever class if found, None otherwise.

    Supported retrievers:
        - google: Google Custom Search
        - searx: SearX search engine
        - searchapi: SearchAPI service
        - serpapi: SerpAPI service
        - serper: Serper API
        - duckduckgo: DuckDuckGo search
        - bing: Bing search
        - arxiv: arXiv academic search
        - tavily: Tavily search API
        - exa: Exa search
        - semantic_scholar: Semantic Scholar academic search
        - pubmed_central: PubMed Central medical literature
        - custom: Custom user-defined retriever
        - mcp: Model Context Protocol retriever
        - xquik: Xquik X/Twitter search
    """
    export = _RETRIEVER_EXPORTS.get(retriever)
    if export is None:
        return None

    module_name, class_name = export
    try:
        module = import_module(module_name)
        return getattr(module, class_name)
    except ImportError as exc:
        raise ImportError(
            f"Retriever `{retriever}` is not available in the slim install. "
            "Use `tavily`, install the full requirements, or install the missing "
            "optional package explicitly."
        ) from exc


def get_retrievers(headers: dict[str, str], cfg):
    """
    Determine which retriever(s) to use based on headers, config, or default.

    Args:
        headers (dict): The headers dictionary
        cfg: The configuration object

    Returns:
        list: A list of retriever classes to be used for searching.
    """
    # Check headers first for multiple retrievers
    if headers.get("retrievers"):
        retrievers = headers.get("retrievers").split(",")
    # If not found, check headers for a single retriever
    elif headers.get("retriever"):
        retrievers = [headers.get("retriever")]
    # If not in headers, check config for multiple retrievers
    elif cfg.retrievers:
        # Handle both list and string formats for config retrievers
        if isinstance(cfg.retrievers, str):
            retrievers = cfg.retrievers.split(",")
        else:
            retrievers = cfg.retrievers
        # Strip whitespace from each retriever name
        retrievers = [r.strip() for r in retrievers]
    # If not found, check config for a single retriever
    elif cfg.retriever:
        retrievers = [cfg.retriever]
    # If still not set, use default retriever
    else:
        retrievers = [get_default_retriever().__name__]

    # Convert retriever names to actual retriever classes
    # Use get_default_retriever() as a fallback for any invalid retriever names
    retriever_classes = [get_retriever(r) or get_default_retriever() for r in retrievers]
    
    return retriever_classes


def get_default_retriever():
    """Get the default retriever class.

    Returns:
        The TavilySearch retriever class as the default search provider.
    """
    return get_retriever("tavily")
