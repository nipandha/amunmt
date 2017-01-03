#include <boost/thread/tss.hpp>
#include "translation_task.h"
#include "search.h"

/*
Histories TranslationTask(std::shared_ptr<Sentences> sentences, size_t taskCounter) {
  thread_local std::unique_ptr<Search> search;
  if(!search) {
    LOG(info) << "Created Search for thread " << std::this_thread::get_id();
    search.reset(new Search(taskCounter));
  }

  assert(sentences->size());
  return search->Decode(*sentences);
}

Histories TranslationTask(const Sentences&& sentences, size_t taskCounter) {
  thread_local std::unique_ptr<Search> search;
  if(!search) {
    LOG(info) << "Created Search for thread " << std::this_thread::get_id();
    search.reset(new Search(taskCounter));
  }

  assert(sentences.size());
  return search->Decode(sentences);
}
*/

Histories TranslationTask(const Sentences& sentences, size_t taskCounter) {
  thread_local std::unique_ptr<Search> search;
  if(!search) {
    LOG(info) << "Created Search for thread " << std::this_thread::get_id();
    search.reset(new Search(taskCounter));
  }

  assert(sentences.size());
  return search->Decode(sentences);
}
