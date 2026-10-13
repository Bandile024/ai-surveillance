create table if not exists public.devices (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    created_at timestamptz not null default now()
);

create table if not exists public.device_credentials (
    device_id uuid primary key references public.devices(id) on delete cascade,
    token_hash text not null unique check (length(token_hash) = 64),
    is_active boolean not null default true,
    created_at timestamptz not null default now()
);

create table if not exists public.device_events (
    id uuid primary key,
    device_id uuid not null references public.devices(id) on delete cascade,
    event_type text not null check (
        event_type in (
            'INTRUSION',
            'MODE_CHANGE',
            'CONTROL_REQUESTED',
            'CONTROL_APPLIED',
            'CONTROL_FAILED'
        )
    ),
    occurred_at timestamptz not null,
    data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
    snapshot_path text,
    created_at timestamptz not null default now(),
    check (event_type = 'INTRUSION' or snapshot_path is null)
);

create index if not exists device_events_device_occurred_idx
    on public.device_events (device_id, occurred_at desc);

alter table public.devices enable row level security;
alter table public.device_credentials enable row level security;
alter table public.device_events enable row level security;

revoke all on public.device_credentials from anon, authenticated;
grant all on public.device_credentials to service_role;

grant select on public.devices to authenticated;
grant select on public.device_events to authenticated;
grant all on public.devices to service_role;
grant all on public.device_events to service_role;

drop policy if exists "Owners can view their devices" on public.devices;
create policy "Owners can view their devices"
    on public.devices for select to authenticated
    using (owner_id = (select auth.uid()));

drop policy if exists "Owners can view device events" on public.device_events;
create policy "Owners can view device events"
    on public.device_events for select to authenticated
    using (
        exists (
            select 1
            from public.devices d
            where d.id = device_events.device_id
              and d.owner_id = (select auth.uid())
        )
    );

do $$
begin
    if not exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'device_events'
    ) then
        alter publication supabase_realtime add table public.device_events;
    end if;
end
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('intrusion-snapshots', 'intrusion-snapshots', false, 8388608, array['image/jpeg'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Owners can view their intrusion snapshots" on storage.objects;
create policy "Owners can view their intrusion snapshots"
    on storage.objects for select to authenticated
    using (
        bucket_id = 'intrusion-snapshots'
        and exists (
            select 1
            from public.device_events e
            join public.devices d on d.id = e.device_id
            where e.snapshot_path = storage.objects.name
              and d.owner_id = (select auth.uid())
        )
    );
