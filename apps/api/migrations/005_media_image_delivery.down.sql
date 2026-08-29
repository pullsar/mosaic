do $$
begin
  if exists (
    select 1
    from media_derivatives
    where purpose = 'image'
  ) then
    raise exception
      'cannot roll back 005_media_image_delivery while managed image derivatives exist';
  end if;
end
$$;

alter table media_derivatives
  drop constraint media_derivatives_purpose_check;

alter table media_derivatives
  add constraint media_derivatives_purpose_check
  check (purpose in ('playback', 'poster', 'audio', 'captions'));
