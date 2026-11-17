PNPM := npx --yes pnpm@10.18.0

.PHONY: web app run dmg clean icon

web:
	cd vendor/chat-demo && $(PNPM) install --frozen-lockfile && $(PNPM) build
	rsync -a --delete vendor/chat-demo/dist/ web/

app:
	./scripts/build-app.sh

run:
	DEEPMACOS_WEB_ROOT=$(CURDIR)/web swift run

dmg: app
	rm -rf dist/dmg dist/DeepmacOS.dmg
	mkdir -p dist/dmg
	cp -R dist/DeepmacOS.app dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname DeepmacOS -srcfolder dist/dmg -ov -format UDZO dist/DeepmacOS.dmg
	@echo "dmg: dist/DeepmacOS.dmg"

clean:
	rm -rf .build dist web
