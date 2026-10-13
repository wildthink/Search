# OKF conformance

Search reads and writes Surfboard catalogs with its own code
(`Sources/Search/Surfboard/Catalog.swift`, linked into this package), not with
[OKFFormat](https://github.com/wildthink/OKFFormat), the format's own
implementation — see that file for why. This package keeps the two honest:
every catalog here, and every `.surfboard` folder named on the command line,
is read by both and compared; then each writes, and the other reads what it
wrote.

    ./run.sh                                   # against OKFFormat's main branch
    ./run.sh ~/Catalogs/Reading.surfboard      # and real catalogs too
    OKF_FORMAT_PATH=../../../OKFFormat ./run.sh   # against a local checkout

Run it after changing `Catalog.swift`, and after OKFFormat changes the format.
