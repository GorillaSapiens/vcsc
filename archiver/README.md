# n65ar

`n65ar` is a small standalone archiver for bundling `.o65` object files into a single `.a65` library file and unpacking them later. Its command line follows the usual GNU `ar` shape for the operations this tool supports.

## Build

```sh
make
```

## Usage

Create or update an archive:

```sh
./n65ar rcs output.a65 obj1.o65 obj2.o65 ... objN.o65
```

List members:

```sh
./n65ar t input.a65
```

Extract all members, or only named members:

```sh
./n65ar x input.a65
./n65ar x input.a65 obj1.o65
```

## Supported operation letters

- `r` ... replace existing members or add new ones
- `q` ... append members
- `t` ... list members
- `x` ... extract members

## Supported modifiers

- `c` ... suppress the "creating archive" message
- `s` ... accepted for GNU `ar` compatibility; no symbol index is written
- `v` ... verbose member-by-member output

The operation-string form above is the preferred interface. The tool also accepts `-c`, `-l`, and `-x` forms.

## Archive format

The format is intentionally simple:

- 7-byte magic: `NAR65\0\1`
- repeated member records until end of file:
  - 16-bit little-endian file name length
  - 32-bit little-endian file size
  - raw file name bytes (basename only, no trailing NUL)
  - raw file contents

## Intentional limitations and format notes

- Member names are stored as basenames only, so extracting does not recreate directories.
- Extraction refuses member names containing `/` or `\`.
- Files larger than 4 GiB are rejected.
- This is a dumb bundle format, not a smart indexed librarian like GNU `ar`; the `s` modifier is accepted only so build scripts can use the usual `rcs` spelling.
