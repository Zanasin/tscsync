# SPDX-License-Identifier: MIT
# make        build tsc-firmware-report.pdf from the committed data
# make data   re-extract the boot history from this machine's journal first

DOC := tsc-firmware-report

$(DOC).pdf: $(DOC).tex data/fit.tex data/warp-vs-firmware.csv
	pdflatex -interaction=nonstopmode -halt-on-error $(DOC).tex
	pdflatex -interaction=nonstopmode -halt-on-error $(DOC).tex

data/fit.tex data/warp-vs-firmware.csv: data/boots.csv analyze.py
	./analyze.py

data:
	./extract-boots.sh > data/boots.csv
	./analyze.py

clean:
	rm -f $(DOC).aux $(DOC).log $(DOC).out $(DOC).pdf

.PHONY: data clean
