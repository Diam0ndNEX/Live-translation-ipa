# Split tools

Helper scripts used in 2.3.3 to 2.3.9 to split big Swift files. Not part of the app or CI.
They were kept from the working session unchanged, so paths inside them may need adjusting.
Not re-tested after being added here.

- splitter.py: reads a Swift type, sorts members, writes Name+Topic.swift parts.
- cut2.py: cuts whole blocks out of a file into a new file (supports EOF).
- sigcheck.py: finds internal methods that expose private types.
- verify.py: line-multiset check before and after a split.

Follow docs/structure-guidelines.md section 4 for the rules.
