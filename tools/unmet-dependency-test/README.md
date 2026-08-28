# Aptkit unmet-dependency test repository

This manual test harness creates a controlled `error-cache-broken` condition
using two inert dummy packages. It is intended for a disposable test device or
virtual machine, not a production system.

The generated repository contains:

| Package | Version | Dependency |
| --- | --- | --- |
| `furios-unmet-lib` | 1.0 | none |
| `furios-unmet-app` | 1.0 | `furios-unmet-lib (= 1.0)` |
| `furios-unmet-lib` | 2.0 | none |
| `furios-unmet-app` | 2.0 | `furios-unmet-lib (= 2.0)` |

The packages contain only a text file under `/usr/share/doc`; they have no
executables, services, configuration files, or maintainer scripts.

## Requirements

Install `dpkg-dev`, `gzip`, and `sudo` on the test system. The script also uses
the standard `apt`, `dpkg`, and `dpkg-deb` tools.

## Test workflow

From this directory, build and enable the local repository and install the
healthy version 1.0 package pair:

```sh
./manage.sh setup
```

Deliberately upgrade only the dummy library to version 2.0:

```sh
./manage.sh break
```

`apt-get check` should now report:

```text
furios-unmet-app: Depends: furios-unmet-lib (= 1.0) but 2.0 is installed
```

The broken state is intentional. Normal APT operations refuse to create it;
the script uses `dpkg --force-depends` on only the dummy library.

Test either recovery implementation:

```sh
sudo furios-update-system
```

Alternatively, refresh updates in GNOME Software. Both implementations should
detect `error-cache-broken`, run Aptkit's `FixBrokenDepends`, and retry their
original operation. The repair should upgrade `furios-unmet-app` to version
2.0 so it matches the already-installed library.

Check the result:

```sh
./manage.sh status
./manage.sh check
```

The expected final versions are:

```text
furios-unmet-lib: 2.0
furios-unmet-app: 2.0
APT dependency state: healthy
```

To see what APT's repair solver would do without changing the test state:

```sh
./manage.sh preview-repair
```

## Cleanup

Remove the two dummy packages, the source-list entry, the repository under
`/var/tmp`, and local build artifacts:

```sh
./manage.sh cleanup
```

Run cleanup even if a test is interrupted. Removing only the repository does
not remove installed packages. The cleanup operation is deliberately scoped to:

- `furios-unmet-app`
- `furios-unmet-lib`
- `/etc/apt/sources.list.d/furios-unmet-dependency-test.list`
- `/var/tmp/furios-unmet-dependency-test-repo`
- this directory's `.build` folder

`furios-update-system` applies all available system updates, not only these
dummy packages. Use a disposable or appropriately isolated test system.
