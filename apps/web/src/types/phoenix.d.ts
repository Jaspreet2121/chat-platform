declare module "phoenix" {
  type ReceiveStatus = "ok" | "error" | "timeout";

  export class Push {
    receive(status: ReceiveStatus, callback: (response?: unknown) => void): Push;
  }

  export class Channel {
    join(timeout?: number): Push;
    leave(timeout?: number): Push;
    push(event: string, payload: object, timeout?: number): Push;
    on(event: string, callback: (payload: unknown) => void): number;
    off(event: string, ref?: number): void;
  }

  export class Socket {
    constructor(
      endPoint: string,
      options?: {
        params?: Record<string, string>;
      }
    );

    connect(params?: Record<string, string>): void;
    disconnect(callback?: () => void, code?: number, reason?: string): void;
    channel(topic: string, chanParams?: object): Channel;
    isConnected(): boolean;
  }
}
