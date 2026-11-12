// LITE build stand-in for heavyweight, lazily imported libraries (shiki grammars, mermaid).
// The Desktop only reaches them through dynamic import() with a fallback, so a module that fails
// to initialise makes that import reject and the UI falls back to plain text.
throw new Error('Not included in the lite plugin-host build')
