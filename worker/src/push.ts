import { Env } from './core';

export interface PushProvider {
  send(deviceToken: string, event: { kind: string; entityId: string }): Promise<void>;
}

// Keep registration and delivery disconnected until a Firebase project and token source are configured.
export function fcmProvider(
  env: Env,
  projectId: string | undefined,
  accessToken: () => Promise<string>,
  transport = fetch,
): PushProvider | null {
  if (env.PUSH_ENABLED !== 'true' || !projectId || !/^[a-z][a-z0-9-]{4,29}$/.test(projectId)) return null;
  return {
    async send(deviceToken, event) {
      const token = await accessToken();
      const response = await transport(
        'https://fcm.googleapis.com/v1/projects/' + projectId + '/messages:send',
        {
          method: 'POST',
          redirect: 'error',
          signal: AbortSignal.timeout(8000),
          headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              token: deviceToken,
              notification: { title: 'Jain Matrimonial', body: 'You have an update. Sign in to view it.' },
              data: { kind: event.kind, entityId: event.entityId },
            },
          }),
        },
      );
      if (!response.ok) throw new Error('Push provider rejected delivery');
    },
  };
}
