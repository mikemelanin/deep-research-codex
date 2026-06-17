"""Lazy exports for document loaders."""

__all__ = ["DocumentLoader", "OnlineDocumentLoader", "LangChainDocumentLoader"]


def __getattr__(name):
    if name == "DocumentLoader":
        from .document import DocumentLoader
        return DocumentLoader
    if name == "OnlineDocumentLoader":
        from .online_document import OnlineDocumentLoader
        return OnlineDocumentLoader
    if name == "LangChainDocumentLoader":
        from .langchain_document import LangChainDocumentLoader
        return LangChainDocumentLoader
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
