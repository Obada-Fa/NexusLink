declare module 'jpeg-js' {
  export function encode(
    image: { data: Buffer | Uint8Array; width: number; height: number },
    quality?: number,
  ): { data: Uint8Array };
  export function decode(data: Buffer | Uint8Array): {
    data: Uint8Array;
    width: number;
    height: number;
  };
}
