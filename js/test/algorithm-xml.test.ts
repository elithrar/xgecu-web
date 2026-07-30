import { describe, expect, it } from "vitest";
import { createAlgorithmXmlProvider } from "../src/algorithm-xml";
import type { AlgorithmRequirement } from "../src/types";

describe("createAlgorithmXmlProvider", () => {
  it("decodes, pads, and digest-checks a T56 payload", async () => {
    const expected = new Uint8Array(512);
    expected.set([0, 0, 0, 0, 0x32, 0x04, 0xc3, 0x49, 1, 2, 3, 4]);
    const requirement: AlgorithmRequirement = {
      programmer: "t56",
      name: "ROM28P41",
      size: expected.byteLength,
      sha256: "bce29b174f85ffce5afb425e8eafd7519139ea6acb3f4581620ebbe127260b22"
    };
    const provider = createAlgorithmXmlProvider(xmlWith(
      "algorithms_T56",
      requirement.name,
      "H4sIAAAAAAAAE2NgYGAwYjnsycjEzAIAj8SVHQwAAAA="
    ));

    await expect(provider(requirement)).resolves.toEqual(expected);
  });

  it("expands a T76 payload with an odd trailing zero", async () => {
    const expected = new Uint8Array([0x34, 0x12, 0, 0, 0, 0, 0]);
    const requirement: AlgorithmRequirement = {
      programmer: "t76",
      name: "ROM28P31",
      size: expected.byteLength,
      sha256: "3964945fd61e63cf4397dfb07a1e6a16b6b480e234bfd4e3e1a5df8789feb1d6"
    };
    const provider = createAlgorithmXmlProvider(xmlWith(
      "algorithms_T76",
      requirement.name,
      "H4sIAAAAAAAAE2NnYGBo33vgp4kQAwMTAwBTPTk1DgAAAA=="
    ));

    await expect(provider(requirement)).resolves.toEqual(expected);
  });

  it("rejects payloads that do not match the catalog digest", async () => {
    const provider = createAlgorithmXmlProvider(xmlWith(
      "algorithms_T56",
      "ROM28P41",
      "H4sIAAAAAAAAE2NgYGAwYjnsycjEzAIAj8SVHQwAAAA="
    ));

    await expect(provider({
      programmer: "t56",
      name: "ROM28P41",
      size: 512,
      sha256: "00".repeat(32)
    })).rejects.toMatchObject({ code: "InvalidAlgorithm" });
  });

  it("stops decompression when a payload exceeds its catalog size", async () => {
    const provider = createAlgorithmXmlProvider(xmlWith(
      "algorithms_T56",
      "ROM28P41",
      "H4sIAAAAAAAAE2NgYGAwYjnsycjEzAIAj8SVHQwAAAA="
    ));

    await expect(provider({
      programmer: "t56",
      name: "ROM28P41",
      size: 1,
      sha256: "00".repeat(32)
    })).rejects.toMatchObject({
      code: "InvalidAlgorithm",
      message: "The decompressed algorithm payload exceeds the catalog size."
    });
  });
});

function xmlWith(section: string, name: string, bitstream: string): string {
  return `<root><${section}><algorithm name="${name}" description="test" bitstream="${bitstream}"></algorithm></${section}></root>`;
}
