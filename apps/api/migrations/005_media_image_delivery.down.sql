alter table media_derivatives
  drop constraint media_derivatives_purpose_check;

alter table media_derivatives
  add constraint media_derivatives_purpose_check
  check (purpose in ('playback', 'poster', 'audio', 'captions'));
