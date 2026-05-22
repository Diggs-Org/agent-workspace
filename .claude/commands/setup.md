# Setup

Run these commands once after container creation to initialize the workspace:

```bash
npm install                                 # installs deps + ESLint
chmod +x .claude/hooks/*.sh                # make hooks executable
python3 scripts/index-codebase.py --full   # build initial codebase index
```
