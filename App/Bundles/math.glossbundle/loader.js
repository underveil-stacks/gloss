// Renders math with KaTeX: ```math blocks, $$…$$ and \[…\] display math,
// \(…\) inline math and GitHub's $`…`$ inline form. A lone $…$ is left alone:
// in technical documents a dollar sign is far more often a price or a shell
// variable than math.
(() => {
  const self = document.currentScript;
  let loading = null;

  function load(file) {
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = new URL(file, self.src).href;
      script.nonce = self.nonce;
      script.onload = resolve;
      script.onerror = () => reject(new Error(`${file} could not be loaded.`));
      document.head.append(script);
    });
  }

  function library() {
    if (!loading) loading = load('katex.min.js').then(() => load('auto-render.min.js'));
    return loading;
  }

  function show(target, source, displayMode) {
    try {
      katex.render(source, target, { displayMode, throwOnError: true });
    } catch (error) {
      target.classList.add('gloss-math-error');
      target.textContent = `Math error: ${error.message || error}`;
    }
  }

  async function render() {
    const article = document.querySelector('.markdown-body');
    if (!article) return;
    try {
      await library();
    } catch (error) {
      console.error(error);
      return;
    }

    for (const code of article.querySelectorAll('pre > code.language-math')) {
      const pre = code.parentElement;
      const block = document.createElement('div');
      block.className = 'gloss-math-block';
      if (pre.dataset.sourcepos) block.dataset.sourcepos = pre.dataset.sourcepos;
      show(block, code.textContent, true);
      pre.replaceWith(block);
    }

    // $`x`$ : inline code with a dollar sign on each side.
    for (const code of article.querySelectorAll('code')) {
      const before = code.previousSibling;
      const after = code.nextSibling;
      if (before?.nodeType === 3 && after?.nodeType === 3 && before.data.endsWith('$') && after.data.startsWith('$')) {
        before.data = before.data.slice(0, -1);
        after.data = after.data.slice(1);
        const span = document.createElement('span');
        show(span, code.textContent, false);
        code.replaceWith(span);
      }
    }

    renderMathInElement(article, {
      delimiters: [
        { left: '$$', right: '$$', display: true },
        { left: '\\[', right: '\\]', display: true },
        { left: '\\(', right: '\\)', display: false },
      ],
      ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code', 'option'],
      ignoredClasses: ['katex', 'gloss-math-block'],
      throwOnError: false,
    });
  }

  document.addEventListener('gloss:render', render);
})();
