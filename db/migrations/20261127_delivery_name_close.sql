-- APPLIED to production 27 Nov 2026 (Supabase migrations "delivery_name_close_spelling_variants" then
-- "delivery_name_close_abbreviations"). Used by delivery_count_candidates for the app's count jobs.
-- 1) supplier spelling variants: boc/buk/pak/bok -> bok, choi/choy -> choy ("Boc Choi" now matches "Bok Choy").
-- 2) a 3+ letter supplier abbreviation that starts a product-name word matches it ("Cucumber LEB" -> "... Lebanese ...").
CREATE OR REPLACE FUNCTION public.delivery_name_close(p_desc text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  with norm as (
    select regexp_replace(regexp_replace(lower(coalesce(p_desc, '')), '\m(boc|buk|pak|bok)\M', 'bok', 'g'), '\m(choi|choy)\M', 'choy', 'g') d,
           regexp_replace(regexp_replace(lower(coalesce(p_name, '')), '\m(boc|buk|pak|bok)\M', 'bok', 'g'), '\m(choi|choy)\M', 'choy', 'g') n),
       dw as (select distinct w from norm, regexp_split_to_table(norm.d, '[^a-z]+') w where length(w) >= 3),
       nw as (select distinct w from norm, regexp_split_to_table(norm.n, '[^a-z]+') w
               where length(w) >= 3
                 and w not in ('organic', 'retail', 'regular', 'bunch', 'bunches', 'punnet', 'punnets', 'each', 'loose',
                               'the', 'and', 'with', 'fresh', 'whole', 'box', 'bag', 'per'))
  select exists (select 1 from nw)
     and not exists (select 1 from nw
                      where not exists (select 1 from dw
                                         where left(dw.w, 4) = left(nw.w, 4)
                                            or nw.w like dw.w || '%'))
$function$;
