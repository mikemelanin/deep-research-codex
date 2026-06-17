"""Lazy exports for context helpers."""

__all__ = ["ContextCompressor", "SearchAPIRetriever"]


def __getattr__(name):
    if name == "ContextCompressor":
        from .compression import ContextCompressor
        return ContextCompressor
    if name == "SearchAPIRetriever":
        from .retriever import SearchAPIRetriever
        return SearchAPIRetriever
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
