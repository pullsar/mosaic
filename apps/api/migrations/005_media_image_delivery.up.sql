alter table media_derivatives
  drop constraint media_derivatives_purpose_check;

alter table media_derivatives
  add constraint media_derivatives_purpose_check
  check (purpose in ('image', 'playback', 'poster', 'audio', 'captions'));
