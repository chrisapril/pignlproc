/*
 * Wikipedia Statistics for Named Entity Recognition and Disambiguation
 */

SET job.name 'Wikipedia-Surface Form -> URI sets for $LANG'

-- Register the project jar to use the custom loaders and UDFs
REGISTER $PIGNLPROC_JAR

-- Define alias for redirect resolver function
DEFINE resolve pignlproc.helpers.SecondIfNotNullElseFirst();

-- Define Ngram generator with maximum Ngram length
DEFINE ngramGenerator pignlproc.helpers.NGramGenerator('$MAX_NGRAM_LENGTH');

--------------------
-- prepare
--------------------

-- Parse the wikipedia dump and extract text and links data
parsed = LOAD '$INPUT'
  USING pignlproc.storage.ParsingWikipediaLoader('$LANG')
  AS (title, id, pageUrl, text, redirect, links, headers, paragraphs);

-- filter as early as possible
SPLIT parsed INTO 
  parsedRedirects IF redirect IS NOT NULL,
  parsedNonRedirects IF redirect IS NULL;

-- Wikipedia IDs
ids = FOREACH parsedNonRedirects GENERATE
  title,
  id,
  pageUrl;

-- Load Redirects and build transitive closure
-- (resolve recursively) in 2 iterations -- 
r1a = FOREACH parsedRedirects GENERATE
  pageUrl AS source1a,
  redirect AS target1a;
r1b = FOREACH r1a GENERATE
  source1a AS source1b,
  target1a AS target1b;
r1join = JOIN
  r1a BY target1a LEFT,
  r1b BY source1b;

r2a = FOREACH r1join GENERATE
  source1a AS source2a,
  flatten(resolve(target1a, target1b)) AS target2a;
r2b = FOREACH r2a GENERATE
  source2a AS source2b,
  target2a AS target2b;
r2join = JOIN
  r2a BY target2a LEFT,
  r2b BY source2b;

redirects = FOREACH r2join GENERATE 
  source2a AS redirectSource,
  FLATTEN(resolve(target2a, target2b)) AS redirectTarget;


-- Project articles
articles = FOREACH parsedNonRedirects GENERATE
  pageUrl,
  text,
  links,
  paragraphs;

-- Extract paragraph contexts of the links 
paragraphs = FOREACH articles GENERATE
  pageUrl,
  FLATTEN(pignlproc.evaluation.ParagraphsWithLink(text, links, paragraphs))
  AS (paragraphIdx, paragraph, targetUri, startPos, endPos);

-- Project to three important relations
pageLinks = FOREACH paragraphs GENERATE
  TRIM(SUBSTRING(paragraph, startPos, endPos)) AS surfaceForm,
  targetUri AS uri,
  pageUrl AS pageUrl;

--Now we have the surface forms

-- Filter out surfaceForms that have zero or one character
pageLinksNonEmptySf = FILTER pageLinks 
  BY SIZE(surfaceForm) >= $MIN_SURFACE_FORM_LENGTH;

-- Resolve redirects  --CHRIS WORKING HERE
pageLinksRedirectsJoin = JOIN
  redirects BY redirectSource RIGHT,
  pageLinksNonEmptySf BY uri;
resolvedLinks = FOREACH pageLinksRedirectsJoin GENERATE
  surfaceForm,
  FLATTEN(resolve(uri, redirectTarget)) AS uri;
distinctLinks = DISTINCT resolvedLinks;

-- we want (sf, {URI, URI, URI,...}, count)
--now Group URI set
sfToUriSet = GROUP distinctLinks BY surfaceForm;

-- project to (sf, {URI}, count) we want
sfToUriFinal = FOREACH sfToUriSet GENERATE
	group, distinctLinks.$1, COUNT(distinctLinks.$1);

--TEST
--Now output to .TSV -Last directory in $dir is hard-coded
STORE sfToUriFinal INTO '$DIR/test_sf_to_Uri_Final.TSV' USING PigStorage();

--TEST
--DUMP sfToUriFinal;
--DESCRIBE sfToUriFinal;


