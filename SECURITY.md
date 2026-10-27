# Security policy

Clenvra deletes files, so bugs in its safety checks are security issues. Examples:

- An item outside what the user selected is removed.
- A protected item is removed: keys, keychains, browser profiles, documents, or excluded folders.
- A symlink, hard link or clone causes the wrong file to be touched.
- Something is deleted permanently when it should have gone to the Trash.
- Privileges are raised without the user's consent.

Please report these privately through GitHub's **Report a vulnerability** button (Security tab), not as a public issue. Include the macOS version, the steps to reproduce, and the Activity log entry if there is one. You can expect a reply within a week.

The rules Clenvra must follow are in [`docs/architecture/safety-model.md`](docs/architecture/safety-model.md).
