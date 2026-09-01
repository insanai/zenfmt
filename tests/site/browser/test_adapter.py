from __future__ import annotations

from playwright.sync_api import Browser, expect


def test_public_adapter_inputs_results_and_errors(
    browser: Browser, site_url: str
) -> None:
    page = browser.new_page()
    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")

    result = page.evaluate(
        """async () => {
          const script = document.querySelector('script[type="module"][data-adapter]');
          const api = await import(new URL(script.dataset.adapter, document.baseURI).href);
          const moduleUrl = new URL(script.dataset.wasm, document.baseURI).href;
          const converter = await api.createConverter({ moduleUrl });
          const encoded = new TextEncoder().encode('# Adapter test\\n\\nBody.\\n');
          const sources = [
            [new File([encoded], 'file.md'), {}],
            [new Blob([encoded]), { name: 'blob.md' }],
            [encoded.buffer.slice(0), { name: 'buffer.md' }],
            [encoded.slice(), { name: 'bytes.md' }],
          ];
          const conversions = [];
          for (const [source, options] of sources) {
            conversions.push(await converter.convert(source, options));
          }

          let missingName = null;
          try {
            await converter.convert(encoded.slice());
          } catch (error) {
            missingName = error;
          }

          const detached = encoded.slice();
          structuredClone(detached.buffer, { transfer: [detached.buffer] });
          let detachedInput = null;
          try {
            await converter.convert(detached, { name: 'detached.md' });
          } catch (error) {
            detachedInput = error;
          }

          const normalized = await api.readSource(encoded, 'normalized.md');
          converter.dispose();
          converter.dispose();
          let disposed = null;
          try {
            await converter.convert(encoded, { name: 'disposed.md' });
          } catch (error) {
            disposed = error;
          }

          const first = conversions[0];
          return {
            exports: Object.keys(api).sort(),
            version: api.version,
            abi: api.abi.version,
            allText: conversions.every((item) => item.text.includes('# Adapter test')),
            conversionClass: first instanceof api.Conversion,
            errorClass: missingName instanceof api.ZenfmtError,
            missingName: missingName?.code,
            detachedInput: detachedInput?.code,
            disposed: disposed?.code,
            frozen: Object.isFrozen(first) && Object.isFrozen(first.reports) &&
              Object.isFrozen(first.resources) && Object.isFrozen(first.manifest),
            normalized: normalized.name === 'normalized.md' &&
              normalized.data !== encoded && normalized.data.length === encoded.length,
            converterClass: converter instanceof api.Converter,
          };
        }"""
    )

    assert result == {
        "exports": [
            "Conversion",
            "Converter",
            "WorkerConverter",
            "ZenfmtError",
            "abi",
            "createConverter",
            "createWorkerConverter",
            "readSource",
            "version",
        ],
        "version": "0.3.7",
        "abi": 0x0001_0000,
        "allText": True,
        "conversionClass": True,
        "errorClass": True,
        "missingName": "browser.missing-source-name",
        "detachedInput": "browser.detached-input",
        "disposed": "browser.disposed",
        "frozen": True,
        "normalized": True,
        "converterClass": True,
    }
    page.close()


def test_worker_cancel_timeout_recovery_and_recycle(
    browser: Browser, site_url: str
) -> None:
    page = browser.new_page()
    workers: list[str] = []
    page.on("worker", lambda worker: workers.append(worker.url))
    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")

    result = page.evaluate(
        """async () => {
          const script = document.querySelector('script[type="module"][data-adapter]');
          const api = await import(new URL(script.dataset.adapter, document.baseURI).href);
          const converter = await api.createWorkerConverter({
            moduleUrl: new URL(script.dataset.wasm, document.baseURI).href,
            workerUrl: new URL(script.dataset.worker, document.baseURI).href,
          });
          const large = new Uint8Array(4 * 1024 * 1024);
          large.fill(0x61);

          const controller = new AbortController();
          const canceledPromise = converter.convert(large, {
            name: 'cancel.txt',
            signal: controller.signal,
          });
          setTimeout(() => controller.abort(), 0);
          let canceled = null;
          try {
            await canceledPromise;
          } catch (error) {
            canceled = error.code;
          }

          let timedOut = null;
          try {
            await converter.convert(large, { name: 'timeout.txt', timeoutMs: 1 });
          } catch (error) {
            timedOut = error.code;
          }

          const tiny = new TextEncoder().encode('tiny\\n');
          let final = null;
          for (let index = 0; index < 25; index += 1) {
            final = await converter.convert(tiny, { name: `tiny-${index}.txt` });
          }
          const recovered = await converter.convert(tiny, { name: 'after-recycle.txt' });
          const workerClass = converter instanceof api.WorkerConverter;
          converter.dispose();
          converter.dispose();
          let disposed = null;
          try {
            await converter.convert(tiny, { name: 'disposed.txt' });
          } catch (error) {
            disposed = error.code;
          }
          return {
            canceled,
            timedOut,
            finalText: final.text,
            recoveredText: recovered.text,
            workerClass,
            disposed,
          };
        }"""
    )

    assert result == {
        "canceled": "browser.canceled",
        "timedOut": "browser.timed-out",
        "finalText": "tiny\n",
        "recoveredText": "tiny\n",
        "workerClass": True,
        "disposed": "browser.disposed",
    }
    # Site worker, explicit API worker, cancellation replacement, timeout
    # replacement, and the bounded-conversion recycle.
    assert len(workers) >= 5
    page.close()
