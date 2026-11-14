// The page's own script. It holds the reader's place across re-renders, makes
// the document's form fields work, and tells bundle scripts when the page has
// (re)rendered. It has no way to reach the app or the disk: the app asks it
// for what it needs.
(() => {
  const blocks = () => document.querySelectorAll('.markdown-body [data-sourcepos]');
  const line = element => parseInt(element.dataset.sourcepos, 10);
  const article = () => document.querySelector('article.markdown-body');
  const clean = text => (text || '').replace(/\s+/g, ' ').trim();

  // Form fields: the document's own controls (sanitized HTML), and fields
  // Gloss makes itself from blanks: an empty table cell, a run of three or
  // more underscores, and a task-list checkbox, which becomes clickable.
  // Values live only in this page until the reader exports them.
  const blankRun = /_{3,}/g;
  const isBlankCell = cell => cell.children.length === 0 && /^(_{3,})?$/.test(cell.textContent.trim());
  const isCheckable = element => element.type === 'checkbox' || element.type === 'radio';

  const forms = {
    built: false,
    fields: [],

    // Turns blanks into fields and indexes every control on the page.
    build() {
      const root = article();
      this.built = true;
      this.fields = [];
      if (!root) return;

      // Only cells the parser made: raw HTML carries no source position.
      for (const cell of root.querySelectorAll('table[data-sourcepos] td[data-sourcepos]')) {
        if (!isBlankCell(cell)) continue;
        const box = document.createElement('textarea');
        box.rows = 1;
        box.className = 'gloss-blank';
        cell.replaceChildren(box);
      }

      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: node =>
          node.parentElement.closest('pre, code, textarea, select, option, a') ||
          !node.parentElement.closest('[data-sourcepos]')
            ? NodeFilter.FILTER_REJECT
            : NodeFilter.FILTER_ACCEPT,
      });
      const texts = [];
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.data.includes('___')) texts.push(node);
      }
      for (const node of texts) {
        const fragment = document.createDocumentFragment();
        node.data.split(blankRun).forEach((piece, index) => {
          if (index > 0) {
            const input = document.createElement('input');
            input.type = 'text';
            input.className = 'gloss-blank';
            fragment.append(input);
          }
          if (piece) fragment.append(piece);
        });
        node.replaceWith(fragment);
      }

      // GitHub task lists: a disabled checkbox the parser writes first in a
      // list item (inside its paragraph, in a loose list).
      for (const item of root.querySelectorAll('li[data-sourcepos]')) {
        let first = item.firstElementChild;
        if (first?.matches('p')) first = first.firstElementChild;
        if (first?.matches('input[type=checkbox][disabled]')) {
          first.disabled = false;
          first.classList.add('gloss-task');
        }
      }

      const headings = [...root.querySelectorAll('h1, h2, h3, h4, h5, h6')];
      const seen = new Map();
      for (const element of root.querySelectorAll('input, textarea, select')) {
        const field = describe(element, headings);
        const base = field.name ? `n:${field.name}` : `p:${field.section}|${field.row}|${field.column}|${field.label}`;
        const ordinal = seen.get(base) || 0;
        seen.set(base, ordinal + 1);
        field.key = `${base}#${ordinal}`;
        field.element = element;
        field.initial = JSON.stringify(stateOf(element));
        // An answer is recorded as typed, not as the system would correct it.
        if (element.matches('input, textarea')) {
          element.setAttribute('autocorrect', 'off');
          element.setAttribute('autocapitalize', 'off');
        }
        this.fields.push(field);
        if (element.matches('textarea')) grow(element);
      }
    },

    count() {
      if (!this.built) this.build();
      return this.fields.length;
    },

    // Every field and its value. Radio buttons, and checkboxes that share a
    // name, are reported once per name.
    values() {
      if (!this.built) this.build();
      const result = [];
      const reported = new Set();
      for (const field of this.fields) {
        const { element } = field;
        const entry = { type: field.type, line: field.line };
        for (const key of ['name', 'section', 'row', 'column', 'label']) if (field[key]) entry[key] = field[key];

        const sharing = field.name && isCheckable(element)
          ? this.fields.filter(f => f.name === field.name && f.type === field.type)
          : [];
        if (field.type === 'radio' && field.name || sharing.length > 1) {
          if (reported.has(field.name)) continue;
          reported.add(field.name);
          const choice = f => (f.element.hasAttribute('value') ? f.element.value : f.label);
          const picked = sharing.filter(f => f.element.checked).map(choice);
          entry.value = field.type === 'radio' ? (picked[0] ?? null) : picked;
          entry.options = sharing.map(choice);
          delete entry.label;
        } else if (isCheckable(element)) {
          entry.value = element.checked;
        } else if (field.type === 'select-multiple') {
          entry.value = [...element.selectedOptions].map(o => o.value);
        } else {
          entry.value = element.value;
        }
        result.push(entry);
      }
      return result;
    },

    // What the reader has entered, by field, to carry across a re-render.
    state() {
      const state = {};
      for (const { key, element } of this.fields) state[key] = stateOf(element);
      return state;
    },

    apply(state) {
      if (!this.built) this.build();
      if (!state) return;
      for (const { key, element } of this.fields) {
        if (!(key in state)) continue;
        const value = state[key];
        if (element.matches('select')) {
          if (Array.isArray(value)) [...element.options].forEach((o, i) => { o.selected = !!value[i]; });
        } else if (isCheckable(element)) {
          element.checked = !!value;
        } else if (typeof value === 'string') {
          element.value = value;
          if (element.matches('textarea')) grow(element);
        }
      }
    },

    // Whether anything differs from how the document set the fields up.
    // (A select's `defaultSelected` is false for the option it shows when no
    // option is marked, so defaults are recorded, not asked for.)
    changed() {
      return this.fields.some(({ element, initial }) => JSON.stringify(stateOf(element)) !== initial);
    },
  };

  function stateOf(element) {
    if (element.matches('select')) return [...element.options].map(o => o.selected);
    if (isCheckable(element)) return element.checked;
    return element.value;
  }

  // Where a control is and what it is about, as a reader would describe it.
  function describe(element, headings) {
    const field = {
      type: element.matches('select')
        ? (element.multiple ? 'select-multiple' : 'select')
        : element.matches('textarea') ? 'textarea' : element.type,
      name: (element.getAttribute('name') || '').replace(/^user-content-/, ''),
      section: '',
      row: '',
      column: '',
      label: '',
      line: null,
    };
    const heading = headings.filter(h => h.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_FOLLOWING).pop();
    if (heading) field.section = clean(heading.textContent);

    const cell = element.closest('td, th');
    if (cell) {
      const first = cell.parentElement.cells[0];
      if (first && first !== cell) field.row = clean(first.textContent);
      const header = cell.closest('table')?.tHead?.rows[0]?.cells[cell.cellIndex];
      if (header) field.column = clean(header.textContent);
    }

    const wrapping = element.closest('label');
    const pointing = element.id ? [...document.querySelectorAll('label[for]')].find(l => l.htmlFor === element.id) : null;
    const aloneInCell = cell && cell.childNodes.length === 1;
    if (element.getAttribute('aria-label')) {
      field.label = clean(element.getAttribute('aria-label'));
    } else if (wrapping || pointing) {
      field.label = clean((wrapping || pointing).textContent);
    } else if (element.classList.contains('gloss-task')) {
      field.label = clean(element.closest('li').textContent);
    } else if (!aloneInCell) {
      // The words just before the control, in the same block.
      const block = element.closest('p, li, td, th, dd, dt, legend, h1, h2, h3, h4, h5, h6') || element.parentElement;
      const range = document.createRange();
      range.setStart(block, 0);
      range.setEndBefore(element);
      // An earlier field in the same sentence reads as the blank it was.
      const before = range.cloneContents();
      before.querySelectorAll('input, textarea, select').forEach(control => control.replaceWith(' ___ '));
      field.label = clean(before.textContent).replace(/[:\s]+$/, '').slice(-80);
    }
    if (!field.label && element.placeholder) field.label = clean(element.placeholder);

    const positioned = element.closest('[data-sourcepos]');
    if (positioned) field.line = line(positioned);
    return field;
  }

  // A text box grows with what is typed into it. Setting a style property is
  // allowed by the page's policy; writing a style attribute is not.
  const sizesItself = window.CSS && CSS.supports('field-sizing', 'content');
  function grow(box) {
    if (sizesItself) return;
    box.style.height = 'auto';
    box.style.height = `${box.scrollHeight}px`;
  }
  document.addEventListener('input', event => {
    if (event.target.matches?.('textarea')) grow(event.target);
  });

  const gloss = {
    forms,

    // The first block still on screen, and where its top edge is.
    anchor() {
      for (const element of blocks()) {
        const rect = element.getBoundingClientRect();
        if (rect.bottom > 0) return { line: line(element), offset: rect.top };
      }
      return null;
    },

    // Put the block nearest that source line back where it was.
    restore(anchor) {
      if (!anchor) return;
      let target = null;
      for (const element of blocks()) {
        target = element;
        if (line(element) >= anchor.line) break;
      }
      if (target) window.scrollBy(0, target.getBoundingClientRect().top - anchor.offset);
    },

    // Swap in a re-rendered document without reloading the page. What the
    // reader has typed is carried across.
    replace(header, article) {
      const anchor = this.anchor();
      const state = forms.state();
      const oldHeader = document.querySelector('header.gloss-frontmatter');
      if (oldHeader) oldHeader.remove();
      document.querySelector('article.markdown-body').outerHTML = article;
      if (header) {
        document.querySelector('article.markdown-body').insertAdjacentHTML('beforebegin', header);
      }
      forms.build();
      forms.apply(state);
      this.restore(anchor);
      this.rendered();
    },

    rendered() {
      document.dispatchEvent(new Event('gloss:render'));
    },

    reveal(id) {
      const element = document.getElementById(id);
      if (element) element.scrollIntoView({ block: 'start' });
    },

    zoom(factor) {
      document.documentElement.style.zoom = factor;
    },
  };

  window.gloss = gloss;
  window.addEventListener('load', () => {
    if (!forms.built) forms.build();
    gloss.rendered();
  });
})();
