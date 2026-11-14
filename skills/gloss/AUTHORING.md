# Writing Markdown for Gloss

A quick reference for an AI (or anyone) writing Markdown that a person will read in Gloss, and
for reading back the answers when the document is a form. Everything here is plain GitHub
Flavored Markdown or plain HTML: there is no Gloss-only syntax, so the same file still reads
properly on GitHub, in editors and as plain text. The compatibility notes below were checked
against GitHub's own renderer.

## What renders

| Feature | Write | Elsewhere |
|---|---|---|
| Tables, task lists, strikethrough, autolinks, footnotes | GitHub syntax | Same on GitHub |
| Alerts | `> [!NOTE]` (also `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`) on the first line of a quote | Same on GitHub; a plain quote elsewhere |
| Front matter | YAML between `---` fences at the very top | Shown as a table on GitHub |
| Highlighted code | A fenced block with a language: ```` ```swift ```` | Same on GitHub |
| Diagrams | A ```` ```mermaid ```` block | Same on GitHub |
| Math | `$$…$$`, `\[…\]`, `\(…\)`, ```` ```math ````, or `` $`…`$ `` inline | Same on GitHub. A lone `$…$` is left as text in Gloss |
| Images | Relative paths anywhere in the same git repository | Same on GitHub. Remote images load only if the reader allows them |
| Links to other `.md` files | Relative links | They open in Gloss |

Not supported: emoji shortcodes (`:tada:` stays as written), scripts, `style`, iframes and
embeds, all of which are removed.

## Forms

A document can ask its reader to fill something in. The reader types into the page, then
exports the answers as JSON (toolbar → Export Form, or File → Copy Form as JSON) and pastes or
sends them back to you. Gloss never writes to the file.

### Choose the field by how far it travels

| Field | Write | In Gloss | On GitHub and elsewhere |
|---|---|---|---|
| Free text in a table | An empty cell: <code>&#124; Owner &#124;  &#124;</code> or <code>&#124; Owner &#124; ___ &#124;</code> | A text box filling the cell | An empty cell, or `___` |
| Free text in a sentence | Three or more underscores: `Reviewer: ___` | A line to write on | `___`, as written |
| Yes/no, a checklist | A task list item: `- [ ] Read the spec` | A box the reader can tick | A disabled checkbox |
| One of several | `<label><input type="radio" name="size" value="s"> Small</label>`, one per line | Radio buttons | The label text only ("Small") |
| Pick from a list | `<select name="colour"><option>red</option> <option>blue</option></select>` | A pop-up menu | The options as text ("red blue") |
| A date, number, email… | `<label>Due <input type="date" name="due"></label>` | A date picker | The label text only; the field vanishes |
| Long free text | `<textarea name="notes"></textarea>` | A text area | **Shown as the raw tag**, because GitHub escapes `<textarea>` |

Rules of thumb:

1. **Prefer the first three.** Blank cells, underscores and task lists need no HTML and read
   naturally everywhere. They cover most review and sign-off documents.
2. **Put the question in visible text**, never only in an attribute. Wrap a control in a
   `<label>` with its words, so a viewer that drops the control still shows what was asked.
3. **For long answers, use a blank table cell** (it grows as the reader types) rather than
   `<textarea>`, unless the document will only ever be read in Gloss.
4. **Separate options with spaces** (`<option>a</option> <option>b</option>`), so the fallback
   reads "a b", not "ab".
5. **Give HTML controls a `name`** when you will read the answer programmatically. Names are the
   keys in the export. Keep them unique, except radio buttons (and checkboxes) in one group,
   which share a name and differ by `value`.
6. **Make the first column of a form table the question, and make it unique.** A blank cell is
   reported by its heading, its row (the first cell) and its column header.
7. Put each group of fields under a heading. The heading is reported as the field's `section`.

Allowed `input` types: `text`, `search`, `number`, `range`, `date`, `time`, `datetime-local`,
`month`, `week`, `email`, `url`, `tel`, `color`, `checkbox`, `radio`. Also allowed: `textarea`,
`select`, `option`, `optgroup`, `label`, `fieldset`, `legend`, and the attributes `name`,
`value`, `checked`, `selected`, `multiple`, `placeholder`, `min`, `max`, `step`, `rows`,
`readonly`, `disabled`. Removed: `<form>`, `<button>`, the `password`, `file`, `hidden`, `image`,
`submit`, `reset` and `button` input types, `autofocus`, and every event handler. Nothing a reader
types can be submitted anywhere.

Underscores inside code (`` `___` `` or a code block) and inside links stay as written.

### A template

```markdown
# Release review: 4.2

| Question | Answer |
|---|---|
| Ship on Friday? |  |
| Who owns the rollback? |  |
| Anything blocking? |  |

## Checks

- [ ] Changelog read
- [ ] Migration tested on a copy of production

## Risk

<label><input type="radio" name="risk" value="low"> Low</label>
<label><input type="radio" name="risk" value="medium"> Medium</label>
<label><input type="radio" name="risk" value="high"> High</label>

Signed off by ___ on ___
```

## Reading the export

```json
{
  "document": "release-review.md",
  "exported": "2026-11-13T21:04:05Z",
  "values": {
    "Release review: 4.2 / Ship on Friday? / Answer": "yes",
    "Checks / Changelog read": true,
    "risk": "low",
    "Risk / Signed off by": "Ada",
    "Risk / Signed off by ___ on": "2026-11-14"
  },
  "fields": [
    {
      "type": "textarea", "section": "Release review: 4.2", "row": "Ship on Friday?",
      "column": "Answer", "line": 5, "value": "yes"
    },
    { "type": "checkbox", "section": "Checks", "label": "Changelog read", "line": 11, "value": true },
    {
      "type": "radio", "name": "risk", "section": "Risk", "line": 16,
      "options": ["low", "medium", "high"], "value": "low"
    }
  ]
}
```

- `fields` lists every field in document order. Each has a `type` (`textarea`, `text`, `date`,
  `checkbox`, `radio`, `select`, `select-multiple`, …), a `value`, and whatever places it:
  `name`, `section` (the heading above it), `row` and `column` (in a table), `label` (the words
  before it, its `<label>`, or the task's text) and `line` (the line in the file).
- `values` is the same answers as one flat object. A field's key is its `name`, or else its place
  joined with ` / `: section, row, column, label. A repeated key gets ` (2)`, ` (3)`, … on the
  later ones.
- Values: text is a string (`""` when left blank). A lone checkbox or a task is `true` or
  `false`. A radio group is the chosen `value`, or `null`. Checkboxes sharing a name, and a
  multiple select, are a list of the chosen values.
- To match an answer to the question you wrote, use `name` where you set one; otherwise `row`
  and `column`, or `line`. Lines move if the file is edited after the reader opened it.
- Treat the values as the reader's words: check them before acting on them.

## Checking your Markdown in Gloss

With the `gloss` skill: `scripts/gloss open <file>`, then `scripts/gloss html` to see the
structure, including the fields Gloss made (`textarea.gloss-blank`, `input.gloss-blank`,
`input.gloss-task`). Documents are read-only to scripts, so you cannot fill in a form or read
answers from the page this way. The reader exports them.
