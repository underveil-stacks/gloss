// Turns ```mermaid code blocks into diagrams. The Mermaid library is large,
// so it is loaded from this bundle only when a page first needs it.
(() => {
  const self = document.currentScript;
  let loading = null;
  let count = 0;

  function library() {
    if (window.mermaid) return Promise.resolve();
    if (!loading) {
      loading = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = new URL('mermaid.min.js', self.src).href;
        script.nonce = self.nonce;
        script.onload = resolve;
        script.onerror = () => reject(new Error('The Mermaid library could not be loaded.'));
        document.head.append(script);
      });
    }
    return loading;
  }

  async function render() {
    const blocks = [...document.querySelectorAll('.markdown-body pre > code.language-mermaid')];
    if (blocks.length === 0) return;
    try {
      await library();
    } catch (error) {
      console.error(error);
      return;
    }
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: document.documentElement.dataset.appearance === 'dark' ? 'dark' : 'default',
    });
    for (const code of blocks) {
      const pre = code.parentElement;
      if (!pre.isConnected) continue;
      const figure = document.createElement('div');
      figure.className = 'gloss-mermaid';
      // Keep the block's place in the source, so the reader's position holds.
      if (pre.dataset.sourcepos) figure.dataset.sourcepos = pre.dataset.sourcepos;
      try {
        const { svg } = await mermaid.render(`gloss-mermaid-${++count}`, code.textContent);
        figure.innerHTML = svg;
      } catch (error) {
        figure.classList.add('gloss-mermaid-error');
        figure.textContent = `Diagram error: ${error.message || error}`;
      }
      pre.replaceWith(figure);
    }
  }

  document.addEventListener('gloss:render', render);
})();
