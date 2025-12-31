export type Follower = {
  id: string;
  email: string;
  created_at: string;
  source: string | null;
  formatted_confirmed_on: string;
  can_update: boolean | null;
};
