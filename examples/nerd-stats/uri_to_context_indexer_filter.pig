/*
 * Wikipedia Statistics for Named Entity Recognition and Disambiguation
 *
 * @params $DIR - the directory where the files should be stored
 *         $INPUT - the wikipedia XML dump
 *         $PIGNLPROC_JAR - the location of the pignlproc jar
 *         $LANG - the language of the Wikidump 
 *         $URI_LIST - a list of URIs to filter by
 */


-- TEST: set parallelism level for reducers
SET default_parallel 15;

SET job.name 'URI to context index for $LANG';

-- Register the project jar to use the custom loaders and UDFs
REGISTER $PIGNLPROC_JAR;

-- Define alias for tokenizer function
DEFINE concatenate pignlproc.helpers.Concatenate();


--------------------
-- prepare
--------------------

-- Parse the wikipedia dump and extract text and links data
parsed = LOAD '$INPUT'
  USING pignlproc.storage.ParsingWikipediaLoader('$LANG')
  AS (title, id, pageUrl, text, redirect, links, headers, paragraphs);


uri_list = LOAD '$URI_LIST' 
   USING PigStorage()
   AS uri: chararray;

-- filter as early as possible
SPLIT parsed INTO 
  parsedRedirects IF redirect IS NOT NULL,
  parsedNonRedirects IF redirect IS NULL;

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

filtered = JOIN paragraphs BY targetUri, uri_list BY uri USING 'replicated';

--Changes for indexing on small cluster
contexts = FOREACH filtered GENERATE
	paragraphs::targetUri AS uri,
	paragraphs::paragraph AS paragraph;

by_uri = GROUP contexts by uri;

--TEST - old code
--flattened = FOREACH by_uri GENERATE
--	group as uri,
--	contexts.paragraph as paragraphs;
--end test

flattened = FOREACH by_uri GENERATE
	group as uri,
	concatenate(contexts.paragraph) as context: chararray;

ordered = order flattened by uri;

--Now output to .TSV --> Last directory in dir is hard-coded for now
STORE ordered INTO '$DIR/uri_to_context_filtered.TSV.bz2' USING PigStorage('\t');

--TEST
--DUMP ordered;
--DESCRIBE ordered;

--TEST
--DUMP ordered;
--DESCRIBE ordered;
-- end test


