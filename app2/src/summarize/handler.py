"""Lambda summarize: disparada por un evento S3 del bucket 'transcripts'.

Transcribe escribe <job>.json a S3-2. Esta Lambda:
  1. Descarga el JSON y extrae la transcripcion completa.
  2. Construye un resumen ejecutivo. Estrategia por prioridad:
       (a) Amazon Comprehend: detect_key_phrases + detect_entities sobre la
           transcripcion; rankea las N frases con mas termos relevantes.
       (b) Fallback extractivo Python puro (TF/IDF-like) si Comprehend da 403.
     No usa Bedrock para no requerir solicitar acceso manual en la consola.
  3. Actualiza el item de DynamoDB: status=COMPLETED + summary.
"""
import json
import math
import os
import re
from collections import Counter

import boto3

TRANSCRIPTS_BUCKET = os.environ["TRANSCRIPTS_BUCKET"]
TABLE_NAME = os.environ["TABLE_NAME"]
# "comprehend" (default) o "extractive" para forzar el fallback.
SUMMARY_MODE = os.environ.get("SUMMARY_MODE", "comprehend")

s3 = boto3.client("s3")
comprehend = boto3.client("comprehend")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        if not key.endswith(".json"):
            continue

        job_name = key.rsplit("/", 1)[-1][: -len(".json")]
        transcript_uri = f"s3://{bucket}/{key}"

        transcript = _extract_transcript(bucket, key)
        if not transcript:
            _mark_failed(job_name, transcript_uri, "transcripcion vacia")
            continue

        try:
            summary = _summarize(transcript)
        except Exception as exc:
            _mark_failed(job_name, transcript_uri, f"summarize error: {exc}")
            continue

        table.update_item(
            Key={"meeting_id": job_name},
            UpdateExpression="SET #s = :s, summary = :sum, "
            "transcript_uri = :t, updated_at = :now",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "COMPLETED",
                ":sum": summary,
                ":t": transcript_uri,
                ":now": _now_iso(),
            },
        )
    return {"summarized": len(event.get("Records", []))}


def _extract_transcript(bucket, key):
    obj = s3.get_object(Bucket=bucket, Key=key)
    data = json.loads(obj["Body"].read().decode("utf-8"))
    try:
        return data["results"]["transcripts"][0]["transcript"]
    except (KeyError, IndexError):
        return ""


def _summarize(transcript):
    sentences = _split_sentences(transcript)
    if not sentences:
        return ""

    mode = SUMMARY_MODE
    if mode == "comprehend":
        try:
            summary = _summarize_comprehend(sentences)
        except Exception as exc:
            # Fallback automatico: Comprehend no disponible (AccessDenied, etc.)
            summary = _summarize_extractive(sentences) + f"\n\n[modo: fallback extractivo (Comprehend no disponible: {exc})]"
    else:
        summary = _summarize_extractive(sentences)
    return summary


# ---------------- Comprehend ----------------
def _summarize_comprehend(sentences):
    # Combina texto para limitar llamadas a Comprehend (limite ~5000 bytes/key_phrases).
    text = " ".join(sentences)[:20000]
    lang = _detect_lang(text)
    # Pide key phrases y nombres detectados
    key_phrases = comprehend.detect_key_phrases(Text=text, LanguageCode=lang)["KeyPhrases"]
    entities = comprehend.detect_entities(Text=text, LanguageCode=lang)["Entities"]
    # Puntua cada frase por cuantas key phrases / entities contiene.
    phrase_set = {kp["Text"].lower().strip() for kp in key_phrases if kp.get("Score", 0) > 0.7}
    entity_set = {e["Text"].lower().strip() for e in entities if e.get("Score", 0) > 0.7}
    keyword_set = phrase_set | entity_set

    scored = []
    for idx, s in enumerate(sentences):
        s_lower = s.lower()
        score = sum(1 for k in keyword_set if k in s_lower)
        scored.append((score, idx, s))
    scored = [t for t in scored if t[0] > 0]
    if not scored:
        scored = [(1, i, s) for i, s in enumerate(sentences)]
    # Top 5 por score, desempata por orden de aparicion
    top = sorted(scored, key=lambda t: (-t[0], t[1]))[:5]
    top = sorted(top, key=lambda t: t[1])
    summary = " ".join(s for _, _, s in top)
    return f"[Resumen extractivo generado con Amazon Comprehend]\n\n{summary}"


def _detect_lang(text):
    try:
        resp = comprehend.detect_dominant_language(Text=text[:4800])
        langs = sorted(resp["Languages"], key=lambda l: l.get("Score", 0), reverse=True)
        code = langs[0]["LanguageCode"] if langs else "es"
        # Comprehend usa ISO 639-1 (es, en, fr). Mapeo defensivo.
        return code if len(code) == 2 else "es"
    except Exception:
        return "es"


# ---------------- Fallback extractivo Python puro ----------------
def _summarize_extractive(sentences):
    # Frequencia de palabras (sin stopwords basicas en es/en)
    stopwords = _STOPWORDS
    word_freq = Counter()
    for s in sentences:
        for w in re.findall(r"\w+", s.lower()):
            if w in stopwords or len(w) < 3:
                continue
            word_freq[w] += 1
    if not word_freq:
        return " ".join(sentences[:5])
    max_freq = max(word_freq.values())
    for w in word_freq:
        word_freq[w] /= max_freq

    scored = []
    for idx, s in enumerate(sentences):
        words = re.findall(r"\w+", s.lower())
        if not words:
            continue
        score = sum(word_freq.get(w, 0) for w in words) / len(words)
        scored.append((score, idx, s))
    top = sorted(scored, key=lambda t: (-t[0], t[1]))[:5]
    top = sorted(top, key=lambda t: t[1])
    return " ".join(s for _, _, s in top)


def _split_sentences(text):
    # Divide por punto/signos tipicos. Suficiente para espanol e ingles.
    parts = re.split(r"(?<=[.!?])\s+", text)
    return [p.strip() for p in parts if p.strip()]


def _mark_failed(job_name, transcript_uri, reason):
    table.update_item(
        Key={"meeting_id": job_name},
        UpdateExpression="SET #s = :s, transcript_uri = :t, "
        "error_message = :e, updated_at = :now",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "FAILED",
            ":t": transcript_uri,
            ":e": reason,
            ":now": _now_iso(),
        },
    )


def _now_iso():
    import datetime

    return datetime.datetime.utcnow().isoformat() + "Z"


_STOPWORDS = {
    # espanol
    "el", "la", "los", "las", "un", "una", "unos", "unas", "y", "o", "de", "del",
    "a", "al", "en", "que", "es", "son", "por", "para", "con", "se", "su", "sus",
    "lo", "le", "les", "muy", "ya", "pero", "mas", "menos", "como", "cuando",
    "donde", "si", "no", "tambien", "esto", "eso", "esa", "este", "estos", "estas",
    "esas", "ha", "han", "hay", "era", "fue", "ser", "nos", "os", "me", "te", "tu",
    "yo", "el", "ellos", "ellas", "ella", "estamos", "estan", "esta", "estoy",
    # ingles
    "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is",
    "are", "was", "were", "be", "been", "we", "you", "they", "he", "she", "it",
    "this", "that", "these", "those", "have", "has", "had", "do", "does", "did",
    "not", "yes", "but", "so", "if",
}